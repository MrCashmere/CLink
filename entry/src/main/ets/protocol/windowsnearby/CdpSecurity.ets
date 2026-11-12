import { LogCapture as Lg } from '../../common/LogCapture';
/**
 * MS-CDP session security primitives.
 *
 * The reference derives the 64-byte session secret with ECDH P-256 + SHA-512:
 *   secret = SHA512(SHA-512) over [SecretPrepend || ECDH_shared || SecretAppend]
 * and authenticates devices with a self-signed X.509 (ECDSA P-256) certificate
 * by signing SHA256(hostNonce_LE || clientNonce_LE || certDER) with the private
 * key of the certificate's public key. The on-wire signature is IEEE P1363
 * (raw r||s, 64 bytes) because Windows/.NET ECDsa uses that by default, while
 * HarmonyOS cryptoFramework emits DER; this module converts between the two.
 *
 * The key import and authentication flow require testing with a Windows peer.
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import certManager from '@ohos.security.cert';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { nativeGenerateCdpIdentity } from 'libmta_core.so';
import { ByteUtils } from '../../common/ByteUtils';
import { CdpCryptor } from './CdpCryptor';

const SECRET_PREPEND = [0x0d6, 0x37, 0x0f1, 0x0aa, 0x0e2, 0x0f0, 0x41, 0x8c];
const SECRET_APPEND = [0x0a8, 0x0f8, 0x1a, 0x57, 0x4e, 0x22, 0x8a, 0x0b7];

export interface CdpPublicPoint {
  readonly x: Uint8Array;
  readonly y: Uint8Array;
}

/** Reverse an 8-byte big-endian field to little-endian (for the auth merge). */
export function toLittleEndian(value: Uint8Array): Uint8Array {
  const out = new Uint8Array(value.length);
  for (let i = 0; i < value.length; i++) {
    out[i] = value[value.length - 1 - i];
  }
  return out;
}

/**
 * Convert a DER (ASN.1 SEQUENCE{r,s}) ECDSA signature into the IEEE P1363
 * format that Windows / .NET ECDsa uses on the wire: fixed r||s, 32 bytes each
 * (64 bytes total for P-256), zero-padded to the field size.
 */
export function derToP1363(der: Uint8Array): Uint8Array {
  if (der.length < 8 || der[0] !== 0x30) {
    throw new Error('CDP sig not DER SEQUENCE');
  }
  const r = CdpSecurity.readDerInt(der, 2);
  const s = CdpSecurity.readDerInt(der, r.nextOffset);
  const rBytes = CdpSecurity.stripLeftZeros(r.value);
  const sBytes = CdpSecurity.stripLeftZeros(s.value);
  const out = new Uint8Array(64);
  out.set(rBytes, 32 - rBytes.length);
  out.set(sBytes, 64 - sBytes.length);
  return out;
}

/**
 * Convert an IEEE P1363 (r||s, 64 bytes) ECDSA signature into the DER
 * (ASN.1 SEQUENCE{r,s}) format that HarmonyOS cryptoFramework expects.
 */
export function p1363ToDer(raw: Uint8Array): Uint8Array {
  if (raw.length !== 64) {
    throw new Error('CDP sig not P1363 (expected 64 bytes)');
  }
  const r = CdpSecurity.derEncodeInt(CdpSecurity.stripLeftZeros(raw.slice(0, 32)));
  const s = CdpSecurity.derEncodeInt(CdpSecurity.stripLeftZeros(raw.slice(32, 64)));
  const body = ByteUtils.concat([r, s]);
  return ByteUtils.concat([new Uint8Array([0x30]), new Uint8Array([body.length]), body]);
}

/** Parse an X.509 SubjectPublicKeyInfo of an uncompressed EC point into (x,y). */
export function parseSpkiPoint(der: Uint8Array): CdpPublicPoint | undefined {
  // Minimal, lenient SPKI walker. Expects:
  //   30 xx  30 yy  06 <alg>   06 <curve>  03 42 00 04 <X> <Y>
  if (der.length < 8) {
    return undefined;
  }
  let offset = 0;
  if (der[offset] !== 0x30) {
    return undefined;
  }
  const seqLen = readDerLen(der, offset + 1);
  offset = offset + 1 + seqLen.lenBytes;
  if (offset >= der.length || der[offset] !== 0x30) {
    return undefined;
  }
  const innerLen = readDerLen(der, offset + 1);
  offset = offset + 1 + innerLen.lenBytes;
  // two OIDs + optional params then BIT STRING
  for (let i = 0; i < 2; i++) {
    if (offset >= der.length || der[offset] !== 0x06) {
      return undefined;
    }
    const oidLen = readDerLen(der, offset + 1);
    offset = offset + 1 + oidLen.lenBytes + oidLen.value;
  }
  if (offset >= der.length || der[offset] !== 0x03) {
    return undefined;
  }
  const bitLen = readDerLen(der, offset + 1);
  offset = offset + 1 + bitLen.lenBytes;
  if (der[offset] !== 0x00) { // unused bits
    return undefined;
  }
  offset += 1;
  if (der[offset] !== 0x04) { // uncompressed point
    return undefined;
  }
  offset += 1;
  if (offset + 64 > der.length) {
    return undefined;
  }
  const point: CdpPublicPoint = {
    x: der.slice(offset, offset + 32),
    y: der.slice(offset + 32, offset + 64)
  };
  return point;
}

function readDerLen(der: Uint8Array, start: number): CdpDerLen {
  const first = der[start];
  if ((first & 0x80) === 0) {
    return new CdpDerLen(1, first);
  }
  const count = first & 0x7f;
  let value = 0;
  for (let i = 0; i < count; i++) {
    value = value * 256 + der[start + 1 + i];
  }
  return new CdpDerLen(count + 1, value);
}

class CdpDerLen {
  readonly lenBytes: number;
  readonly value: number;

  constructor(lenBytes: number, value: number) {
    this.lenBytes = lenBytes;
    this.value = value;
  }
}

/** Build an X.509 SubjectPublicKeyInfo from an uncompressed EC point (x||y). */
export function buildSpkiPoint(point: CdpPublicPoint): Uint8Array {
  const body = ByteUtils.concat([new Uint8Array([0x04]), point.x, point.y]);
  const bitString = ByteUtils.concat([
    new Uint8Array([0x03, 0x42, 0x00]), body
  ]);
  // AlgorithmIdentifier: SEQUENCE { id-ecPublicKey (1.2.840.10045.2.1),
  // prime256v1 (1.2.840.10045.3.1.7) }. Content = 19 bytes -> 0x13.
  const algId = ByteUtils.fromHex('301306072a8648ce3d020106082a8648ce3d030107');
  const inner = ByteUtils.concat([algId, bitString]);
  const outer = ByteUtils.concat([new Uint8Array([0x30, inner.length]), inner]);
  return outer;
}

interface CdpIdentityData {
  readonly certificateHex: string;
  readonly privateKeyHex: string;
  readonly publicKeyHex: string;
}

export class CdpSecurity {
  private static readonly identities: Map<string, Promise<CdpSecurity>> = new Map();
  private readonly certDer: Uint8Array;
  private readonly keyDer: Uint8Array;
  private readonly point: CdpPublicPoint;
  private keyPair?: cryptoFramework.KeyPair;
  private constructor(certDer: Uint8Array, keyDer: Uint8Array, point: CdpPublicPoint) {
    this.certDer = certDer;
    this.keyDer = keyDer;
    this.point = point;
  }

  static async load(context: common.Context): Promise<CdpSecurity> {
    const directory = context.filesDir;
    const pending = CdpSecurity.identities.get(directory);
    if (pending !== undefined) { return await pending; }
    const created = CdpSecurity.loadIdentity(directory);
    CdpSecurity.identities.set(directory, created);
    try {
      return await created;
    } catch (error) {
      if (CdpSecurity.identities.get(directory) === created) { CdpSecurity.identities.delete(directory); }
      throw error as Error;
    }
  }

  private static async loadIdentity(directory: string): Promise<CdpSecurity> {
    const destination = directory + '/windows-nearby-identity-v1.json';
    try {
      if (fs.accessSync(destination) && fs.statSync(destination).size <= 8192) {
        return await CdpSecurity.decodeIdentity(await fs.readText(destination));
      }
    } catch (_error) {
      // Corrupt or incompatible local identity; replace it with a fresh pair.
    }
    const serialized: string = await nativeGenerateCdpIdentity();
    const identity = await CdpSecurity.decodeIdentity(serialized);
    const temporaryDir = fs.mkdtempSync(directory + '/cdp-identity-XXXXXX');
    try {
      const temporary = temporaryDir + '/identity.json';
      const file = fs.openSync(temporary, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE);
      try {
        const bytes = ByteUtils.encodeText(serialized);
        if (fs.writeSync(file.fd, ByteUtils.toArrayBuffer(bytes)) !== bytes.length) {
          throw new Error('CDP: failed to persist the local identity');
        }
        fs.fsyncSync(file.fd);
      } finally {
        fs.closeSync(file);
      }
      fs.renameSync(temporary, destination);
      return identity;
    } finally {
      try { fs.rmdirSync(temporaryDir); } catch (_error) {}
    }
  }

  private static async decodeIdentity(serialized: string): Promise<CdpSecurity> {
    const data = JSON.parse(serialized) as CdpIdentityData;
    const cert = CdpSecurity.decodeDer(data.certificateHex);
    const key = CdpSecurity.decodeDer(data.privateKeyHex);
    const point = parseSpkiPoint(CdpSecurity.decodeDer(data.publicKeyHex));
    const embedded = await CdpSecurity.pointFromCertificate(cert);
    if (point === undefined || embedded === undefined ||
      ByteUtils.toHex(embedded.x) !== ByteUtils.toHex(point.x) ||
      ByteUtils.toHex(embedded.y) !== ByteUtils.toHex(point.y)) {
      throw new Error('CDP: invalid local certificate');
    }
    const result = new CdpSecurity(cert, key, point);
    await result.ensureKeyPair();
    return result;
  }

  private static decodeDer(value: string): Uint8Array {
    if (typeof value !== 'string' || value.length === 0 || value.length > 4096 ||
      value.length % 2 !== 0 || !/^[0-9a-f]+$/i.test(value)) {
      throw new Error('CDP: malformed local identity');
    }
    return ByteUtils.fromHex(value);
  }

  get certificateDer(): Uint8Array {
    return this.certDer;
  }

  get publicPoint(): CdpPublicPoint {
    return this.point;
  }

  private async ensureKeyPair(): Promise<cryptoFramework.KeyPair> {
    if (this.keyPair !== undefined) {
      return this.keyPair;
    }
    const generator = cryptoFramework.createAsyKeyGenerator('ECC256');
    const pair = await generator.convertKey({ data: buildSpkiPoint(this.point) }, { data: this.keyDer });
    this.keyPair = pair;
    return pair;
  }

  /** ECDH P-256 shared secret -> 64-byte session secret. */
  async deriveSharedSecret(remoteX: Uint8Array, remoteY: Uint8Array): Promise<Uint8Array> {
    const pair = await this.ensureKeyPair();
    const remotePoint: CdpPublicPoint = { x: remoteX, y: remoteY };
    const remoteSpki = buildSpkiPoint(remotePoint);
    const generator = cryptoFramework.createAsyKeyGenerator('ECC256');
    // Remote public-key-only import: pass null for the private key (an empty
    // DataBlob is rejected at runtime by cryptoFramework).
    const remotePair = await generator.convertKey({ data: remoteSpki }, null);
    const agreement = cryptoFramework.createKeyAgreement('ECC256');
    const shared = await agreement.generateSecret(pair.priKey, remotePair.pubKey);
    const ecdh = new Uint8Array(shared.data);
    const input = ByteUtils.concat([new Uint8Array(SECRET_PREPEND), ecdh, new Uint8Array(SECRET_APPEND)]);
    const md = cryptoFramework.createMd('SHA512');
    await md.update({ data: input });
    const digest = await md.digest();
    return new Uint8Array(digest.data);
  }

  /** Sign SHA256(hostNonceLE || clientNonceLE || certDER) with our private key. */
  async signThumbprint(hostNonce: Uint8Array, clientNonce: Uint8Array): Promise<Uint8Array> {
    const pair = await this.ensureKeyPair();
    const data = ByteUtils.concat([toLittleEndian(hostNonce), toLittleEndian(clientNonce), this.certDer]);
    const signer = cryptoFramework.createSign('ECC256|SHA256');
    await signer.init(pair.priKey);
    const signature = await signer.sign({ data });
    // HarmonyOS emits DER; Windows / .NET ECDsa emits (and expects) IEEE P1363.
    return derToP1363(new Uint8Array(signature.data));
  }

  /** Verify a remote thumbprint using the remote certificate's embedded public key. */
  async verifyThumbprint(certDer: Uint8Array, signature: Uint8Array, hostNonce: Uint8Array, clientNonce: Uint8Array): Promise<boolean> {
    const certPoint = await CdpSecurity.pointFromCertificate(certDer);
    Lg.i('羊绒互传 CdpSecurity: verifyThumbprint certPoint=' + (certPoint !== undefined) + ' sigLen=' + signature.length);
    if (certPoint === undefined) {
      return false;
    }
    const generator = cryptoFramework.createAsyKeyGenerator('ECC256');
    const remotePair = await generator.convertKey({ data: buildSpkiPoint(certPoint) }, null);
    const data = ByteUtils.concat([toLittleEndian(hostNonce), toLittleEndian(clientNonce), certDer]);
    try {
      const der = p1363ToDer(signature);
      const verifier = cryptoFramework.createVerify('ECC256|SHA256');
      await verifier.init(remotePair.pubKey);
      const ok = await verifier.verify({ data }, { data: der });
      Lg.i('羊绒互传 CdpSecurity: verifyThumbprint verify=' + ok);
      return ok;
    } catch (error) {
      Lg.w('羊绒互传 CdpSecurity: verifyThumbprint error: ' + JSON.stringify(error));
      return false;
    }
  }

  /** Derive a CdpCryptor from the 64-byte session secret. */
  static createCryptor(secret: Uint8Array): CdpCryptor {
    return new CdpCryptor(secret);
  }

  /**
   * Minimum viable point extraction from an X.509 certificate: the SubjectPublicKeyInfo
   * of a self-signed cert is located after the TBS + AlgorithmIdentifier; we find the
   * final BIT STRING (0x03 ... 0x00 0x04 X Y). If parsing fails we return undefined and
   * the caller degrades the verification to a best-effort check.
   */
  private static async pointFromCertificate(der: Uint8Array): Promise<CdpPublicPoint | undefined> {
    try {
      const certificate = await certManager.createX509Cert({
        data: der, encodingFormat: certManager.EncodingFormat.FORMAT_DER
      });
      return parseSpkiPoint(certificate.getPublicKey().getEncoded().data);
    } catch (_error) {
      return undefined;
    }
  }

  /** Read a DER INTEGER (0x02 <len> <value>) at an offset. */
  static readDerInt(der: Uint8Array, offset: number): CdpDerInt {
    if (offset + 2 > der.length || der[offset] !== 0x02) {
      throw new Error('CDP sig DER: expected INTEGER');
    }
    const length = der[offset + 1];
    if (offset + 2 + length > der.length) {
      throw new Error('CDP sig DER: INTEGER overflows');
    }
    return new CdpDerInt(der.slice(offset + 2, offset + 2 + length), offset + 2 + length);
  }

  /** Encode an unsigned integer as a DER INTEGER (0x02 <len> <value>). */
  static derEncodeInt(value: Uint8Array): Uint8Array {
    const body = value.length > 0 && (value[0] & 0x80) !== 0
      ? ByteUtils.concat([new Uint8Array([0x00]), value])
      : value;
    return ByteUtils.concat([new Uint8Array([0x02, body.length]), body]);
  }

  /** Strip leading zero octets, keeping at least one byte. */
  static stripLeftZeros(value: Uint8Array): Uint8Array {
    let start = 0;
    while (start < value.length - 1 && value[start] === 0) {
      start++;
    }
    return value.slice(start);
  }
}

class CdpDerInt {
  readonly value: Uint8Array;
  readonly nextOffset: number;

  constructor(value: Uint8Array, nextOffset: number) {
    this.value = value;
    this.nextOffset = nextOffset;
  }
}
