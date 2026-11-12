import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { GsBytes } from '../util/GsBytes';
import { GsCrypto } from '../util/GsCrypto';
import { ProtoWire } from './ProtoWire';
import { ProtoReader } from './ProtoReader';
import { SecureMessage, SecureKeys } from './SecureMessage';

export type Ukey2Role = 'client' | 'server';

const ECC_ALG = 'ECC256';
const NEXT_PROTOCOL = 'AES_256_CBC-HMAC_SHA256';
const P256_SHA512 = 100;

const D2D_SALT: Uint8Array = new Uint8Array([
  0x82, 0xAA, 0x55, 0xA0, 0xD3, 0x97, 0xF8, 0x83,
  0x46, 0xCA, 0x1C, 0xEE, 0x8D, 0x39, 0x09, 0xB9,
  0x5F, 0x13, 0xFA, 0x7D, 0xEB, 0x1D, 0x4A, 0xB3,
  0x83, 0x76, 0xB8, 0x25, 0x6D, 0xA8, 0x55, 0x10
]);

interface EcPoint {
  readonly x: Uint8Array;
  readonly y: Uint8Array;
}

interface DerLen {
  readonly lenBytes: number;
  readonly value: number;
}

/**
 * UKEY2-style handshake that is byte-compatible with Android Quick Share /
 * NearDrop:
 *
 *   ClientInit(2) -> ServerInit(3) -> ClientFinish(4) -> Established
 *
 * - ECDH P-256, commitment = SHA512(full serialized Ukey2Message). This module
 *   is driven by an explicit state machine. Evidence: docs/UKEY2.md and the
 *   public NearDrop protocol definitions and reference implementation.
 * - After key exchange both peers derive the D2D + SecureMessage keys using the
 *   NearDrop HKDF chain (auth / next / client / server / ENC:2 / SIG:1).
 * - encrypt/decrypt wrap an already-serialized frame in a SecureMessage
 *   (AES-256-CBC + HMAC-SHA256). This repo's envelope does not yet emit the
 *   DeviceToDeviceMessage sequence wrapper (see docs/UNVERIFIED.md).
 */
export class UKEY2Handshake {
  private keyPair?: cryptoFramework.KeyPair;
  private remotePubKey?: cryptoFramework.PubKey;
  private clientInitMsgData: Uint8Array = new Uint8Array(0);
  private serverInitMsgData: Uint8Array = new Uint8Array(0);
  private clientFinishMsgData: Uint8Array = new Uint8Array(0);
  private cipherCommitment: Uint8Array = new Uint8Array(0);
  private sendKeys?: SecureKeys;
  private recvKeys?: SecureKeys;
  private sendSeq: number = 0;
  private recvSeq: number = 0;
  private authPin: string = '';
  private verified: boolean = false;

  private readonly role: Ukey2Role;

  constructor(role: Ukey2Role) {
    this.role = role;
  }

  get pin(): string {
    return this.authPin;
  }

  get isVerified(): boolean {
    return this.verified;
  }

  async prepare(): Promise<void> {
    const generator = cryptoFramework.createAsyKeyGenerator(ECC_ALG);
    this.keyPair = await generator.generateKeyPair();
  }

  // ---- Public wire builders ----

  /** Client: build the full Ukey2Message(CLIENT_INIT) and remember its bytes. */
  async buildClientInit(): Promise<Uint8Array> {
    const pair = this.keyPair;
    if (pair === undefined) {
      throw new Error('UKEY2: not prepared');
    }
    const point = await UKEY2Handshake.publicPoint(pair);
    this.clientFinishMsgData = UKEY2Handshake.encodeUkey2Message(4, UKEY2Handshake.encodeClientFinished(point));
    const commitment = await GsCrypto.sha512(this.clientFinishMsgData);
    const random = await GsCrypto.randomBytes(32);
    const cipherCommitment = ProtoWire.message([
      ProtoWire.fieldEnum(1, P256_SHA512),
      ProtoWire.fieldBytes(2, commitment)
    ]);
    const clientInit = ProtoWire.message([
      ProtoWire.fieldInt32(1, 1),
      ProtoWire.fieldBytes(2, random),
      ProtoWire.nested(3, cipherCommitment),
      ProtoWire.fieldString(4, NEXT_PROTOCOL)
    ]);
    this.clientInitMsgData = UKEY2Handshake.encodeUkey2Message(2, clientInit);
    return this.clientInitMsgData;
  }

  /** Server: parse ClientInit, choose P256_SHA512, build + cache ServerInit. */
  async buildServerInit(clientInit: Uint8Array): Promise<Uint8Array> {
    if (ProtoReader.firstVarint(clientInit, 1) !== 2) {
      throw new Error('UKEY2: expected ClientInit');
    }
    const body = ProtoReader.firstBytes(clientInit, 2);
    if (body === undefined) {
      throw new Error('UKEY2: ClientInit missing message_data');
    }
    if ((ProtoReader.firstVarint(body, 1) ?? 0) !== 1) {
      throw new Error('UKEY2: bad version');
    }
    const random = ProtoReader.firstBytes(body, 2);
    if (random === undefined || random.length !== 32) {
      throw new Error('UKEY2: bad random');
    }
    if (GsBytes.decodeText(ProtoReader.firstBytes(body, 4) ?? new Uint8Array(0)) !== NEXT_PROTOCOL) {
      throw new Error('UKEY2: bad next protocol');
    }
    let commitment: Uint8Array | undefined = undefined;
    for (const entry of ProtoReader.allBytes(body, 3)) {
      if ((ProtoReader.firstVarint(entry, 1) ?? 0) === P256_SHA512) {
        commitment = ProtoReader.firstBytes(entry, 2);
        break;
      }
    }
    if (commitment === undefined) {
      throw new Error('UKEY2: no P256_SHA512 commitment');
    }
    this.cipherCommitment = commitment;
    this.clientInitMsgData = clientInit;

    const pair = this.keyPair;
    if (pair === undefined) {
      throw new Error('UKEY2: not prepared');
    }
    const point = await UKEY2Handshake.publicPoint(pair);
    const serverRandom = await GsCrypto.randomBytes(32);
    const serverInit = ProtoWire.message([
      ProtoWire.fieldInt32(1, 1),
      ProtoWire.fieldBytes(2, serverRandom),
      ProtoWire.fieldEnum(3, P256_SHA512),
      ProtoWire.fieldBytes(4, UKEY2Handshake.encodeGenericPublicKey(point))
    ]);
    this.serverInitMsgData = UKEY2Handshake.encodeUkey2Message(3, serverInit);
    return this.serverInitMsgData;
  }

  /** Client: parse ServerInit, run key exchange, return the cached ClientFinish. */
  async buildClientFinish(serverInit: Uint8Array): Promise<Uint8Array> {
    if (ProtoReader.firstVarint(serverInit, 1) !== 3) {
      throw new Error('UKEY2: expected ServerInit');
    }
    const body = ProtoReader.firstBytes(serverInit, 2);
    if (body === undefined) {
      throw new Error('UKEY2: ServerInit missing message_data');
    }
    const peerKey = ProtoReader.firstBytes(body, 4);
    if (peerKey === undefined) {
      throw new Error('UKEY2: ServerInit missing public_key');
    }
    this.serverInitMsgData = serverInit;
    const point = UKEY2Handshake.decodeGenericPublicKey(peerKey);
    await this.finalizeKeyExchange(point);
    return this.clientFinishMsgData;
  }

  /** Server: verify commitment + ClientFinish pubkey, then finalize keys. */
  async processClientFinish(finish: Uint8Array): Promise<void> {
    if (ProtoReader.firstVarint(finish, 1) !== 4) {
      throw new Error('UKEY2: expected ClientFinish');
    }
    const digest = await GsCrypto.sha512(finish);
    if (!UKEY2Handshake.equal(digest, this.cipherCommitment)) {
      throw new Error('UKEY2: commitment mismatch');
    }
    const body = ProtoReader.firstBytes(finish, 2);
    if (body === undefined) {
      throw new Error('UKEY2: ClientFinish missing message_data');
    }
    const pubKey = ProtoReader.firstBytes(body, 1);
    if (pubKey === undefined) {
      throw new Error('UKEY2: ClientFinish missing public_key');
    }
    const point = UKEY2Handshake.decodeGenericPublicKey(pubKey);
    await this.finalizeKeyExchange(point);
  }

  markVerified(): void {
    if (this.sendKeys === undefined || this.recvKeys === undefined) {
      throw new Error('UKEY2: keys not derived');
    }
    this.verified = true;
  }

  async encrypt(frame: Uint8Array): Promise<Uint8Array> {
    if (this.sendKeys === undefined) {
      throw new Error('UKEY2: not established');
    }
    this.sendSeq += 1;
    // After the handshake every payload is a DeviceToDeviceMessage
    // { message = OfflineFrame, sequence_number = monotonic } sealed inside the
    // SecureMessage. Android rejects/bv-ignores a SecureMessage whose body is not
    // wrapped in DeviceToDeviceMessage, so it never sends PairedKeyResult.
    const d2d = ProtoWire.message([
      ProtoWire.fieldBytes(1, frame),
      ProtoWire.fieldVarint(2, this.sendSeq)
    ]);
    return SecureMessage.seal(this.sendKeys, d2d, this.sendSeq);
  }

  async decrypt(packet: Uint8Array): Promise<Uint8Array> {
    if (this.recvKeys === undefined) {
      throw new Error('UKEY2: not established');
    }
    this.recvSeq += 1;
    const d2d = await SecureMessage.open(this.recvKeys, packet, this.recvSeq);
    const message = ProtoReader.firstBytes(d2d, 1);
    if (message === undefined) {
      throw new Error('UKEY2: DeviceToDeviceMessage missing payload');
    }
    return message;
  }

  // ---- Key exchange ----

  private async finalizeKeyExchange(peer: EcPoint): Promise<void> {
    const myPair = this.keyPair;
    if (myPair === undefined) {
      throw new Error('UKEY2: not prepared');
    }
    const remotePoint = UKEY2Handshake.normalizePoint(peer);
    const spki = UKEY2Handshake.buildSpkiPoint(remotePoint);
    const generator = cryptoFramework.createAsyKeyGenerator(ECC_ALG);
    const converted = await generator.convertKey({ data: spki }, null);
    this.remotePubKey = converted.pubKey;
    const agreement = cryptoFramework.createKeyAgreement(ECC_ALG);
    const secret = await agreement.generateSecret(myPair.priKey, this.remotePubKey);
    const shared = new Uint8Array(secret.data);
    const derivedSecretKey = await GsCrypto.sha256(shared);

    const ukeyInfo = GsBytes.concat([this.clientInitMsgData, this.serverInitMsgData]);
    const authString = await GsCrypto.hkdfSha256(derivedSecretKey, GsBytes.encodeText('UKEY2 v1 auth'), ukeyInfo, 32);
    const nextSecret = await GsCrypto.hkdfSha256(derivedSecretKey, GsBytes.encodeText('UKEY2 v1 next'), ukeyInfo, 32);
    this.authPin = GsCrypto.pinFromBytes(authString);

    const d2dClientKey = await GsCrypto.hkdfSha256(nextSecret, D2D_SALT, GsBytes.encodeText('client'), 32);
    const d2dServerKey = await GsCrypto.hkdfSha256(nextSecret, D2D_SALT, GsBytes.encodeText('server'), 32);
    const smsgSalt = await GsCrypto.sha256(GsBytes.encodeText('SecureMessage'));
    const clientEnc = await GsCrypto.hkdfSha256(d2dClientKey, smsgSalt, GsBytes.encodeText('ENC:2'), 32);
    const clientSig = await GsCrypto.hkdfSha256(d2dClientKey, smsgSalt, GsBytes.encodeText('SIG:1'), 32);
    const serverEnc = await GsCrypto.hkdfSha256(d2dServerKey, smsgSalt, GsBytes.encodeText('ENC:2'), 32);
    const serverSig = await GsCrypto.hkdfSha256(d2dServerKey, smsgSalt, GsBytes.encodeText('SIG:1'), 32);

    if (this.role === 'server') {
      this.sendKeys = { enc: serverEnc, sig: serverSig };
      this.recvKeys = { enc: clientEnc, sig: clientSig };
    } else {
      this.sendKeys = { enc: clientEnc, sig: clientSig };
      this.recvKeys = { enc: serverEnc, sig: serverSig };
    }
  }

  // ---- Static wire / DER helpers ----

  private static async publicPoint(pair: cryptoFramework.KeyPair): Promise<EcPoint> {
    const der = new Uint8Array(pair.pubKey.getEncoded().data);
    const point = UKEY2Handshake.parseEcPoint(der);
    if (point === undefined) {
      console.error('[UKEY2] cannot parse local EC public key len=' + der.length);
      throw new Error('UKEY2: cannot parse local EC public key');
    }
    return point;
  }

  /** Accept SPKI DER and raw uncompressed point (0x04||X||Y). */
  private static parseEcPoint(der: Uint8Array): EcPoint | undefined {
    const spki = UKEY2Handshake.parseSpkiPoint(der);
    if (spki !== undefined) {
      return spki;
    }
    if (der.length === 65 && der[0] === 0x04) {
      return { x: der.slice(1, 33), y: der.slice(33, 65) };
    }
    for (let i = 0; i + 65 <= der.length; i++) {
      if (der[i] === 0x04) {
        const candidate: EcPoint = { x: der.slice(i + 1, i + 33), y: der.slice(i + 33, i + 65) };
        const ok = UKEY2Handshake.validPoint(candidate);
        if (ok) {
          return candidate;
        }
      }
    }
    return undefined;
  }

  /** Cheap sanity check that x,y are non-trivial 32-byte coordinates. */
  private static validPoint(point: EcPoint): boolean {
    if (point.x.length !== 32 || point.y.length !== 32) {
      return false;
    }
    let nonzero = false;
    for (let i = 0; i < point.x.length && point.y.length; i++) {
      if (point.x[i] !== 0 || point.y[i] !== 0) {
        nonzero = true;
        break;
      }
    }
    return nonzero;
  }

  private static encodeUkey2Message(messageType: number, messageData: Uint8Array): Uint8Array {
    return ProtoWire.message([
      ProtoWire.fieldEnum(1, messageType),
      ProtoWire.fieldBytes(2, messageData)
    ]);
  }

  private static encodeClientFinished(point: EcPoint): Uint8Array {
    return ProtoWire.message([
      ProtoWire.fieldBytes(1, UKEY2Handshake.encodeGenericPublicKey(point))
    ]);
  }

  private static encodeGenericPublicKey(point: EcPoint): Uint8Array {
    const ecKey = ProtoWire.message([
      ProtoWire.fieldBytes(1, UKEY2Handshake.toSignedBytes(point.x)),
      ProtoWire.fieldBytes(2, UKEY2Handshake.toSignedBytes(point.y))
    ]);
    return ProtoWire.message([
      ProtoWire.fieldEnum(1, 1),
      ProtoWire.fieldBytes(2, ecKey)
    ]);
  }

  // NearDrop/Android encode the EC coordinates with BInt.asSignedBytes()
  // (minimal big-endian, a leading 0x00 when the high bit is set). This is the
  // byte-for-byte form Android's GenericPublicKey parser expects; a raw 32-byte
  // unsigned coordinate with the high bit set is interpreted as invalid/negative.
  private static toSignedBytes(value: Uint8Array): Uint8Array {
    let start = 0;
    while (start < value.length - 1 && value[start] === 0) {
      start++;
    }
    const body = value.slice(start);
    if (body.length > 0 && (body[0] & 0x80) !== 0) {
      const out = new Uint8Array(body.length + 1);
      out[0] = 0;
      out.set(body, 1);
      return out;
    }
    return body;
  }

  private static decodeGenericPublicKey(bytes: Uint8Array): EcPoint {
    const ecKey = ProtoReader.firstBytes(bytes, 2);
    if (ecKey === undefined) {
      throw new Error('UKEY2: missing ec_p256_public_key');
    }
    const x = ProtoReader.firstBytes(ecKey, 1);
    const y = ProtoReader.firstBytes(ecKey, 2);
    if (x === undefined || y === undefined) {
      throw new Error('UKEY2: malformed EC point');
    }
    return { x, y };
  }

  private static normalizePoint(point: EcPoint): EcPoint {
    return { x: UKEY2Handshake.trim32(point.x), y: UKEY2Handshake.trim32(point.y) };
  }

  private static trim32(value: Uint8Array): Uint8Array {
    if (value.length > 32) {
      return value.slice(value.length - 32);
    }
    if (value.length === 32) {
      return value;
    }
    const out = new Uint8Array(32);
    out.set(value, 32 - value.length);
    return out;
  }

  private static buildSpkiPoint(point: EcPoint): Uint8Array {
    const body = GsBytes.concat([new Uint8Array([0x04]), point.x, point.y]);
    const bitString = GsBytes.concat([new Uint8Array([0x03, 0x42, 0x00]), body]);
    // AlgorithmIdentifier for id-ecPublicKey + prime256v1. SEQUENCE length is
    // 0x13 (19 bytes: two OIDs), NOT 0x07; the previous value made the ASN.1
    // parser read the nested OID's tag as part of the first OID, which is why
    // HarmonyOS convertKey() returned "d2i_EC_PUBKEY fail / wrong tag".
    const algId = GsBytes.fromHex('301306072a8648ce3d020106082a8648ce3d030107');
    const inner = GsBytes.concat([algId, bitString]);
    return GsBytes.concat([new Uint8Array([0x30, inner.length]), inner]);
  }

  private static parseSpkiPoint(der: Uint8Array): EcPoint | undefined {
    if (der.length < 8 || der[0] !== 0x30) {
      return undefined;
    }
    let offset = 0;
    const seqLen = UKEY2Handshake.readDerLen(der, offset + 1);
    if (seqLen.lenBytes === 0) {
      return undefined;
    }
    offset = offset + 2 + seqLen.lenBytes;
    if (offset >= der.length || der[offset] !== 0x30) {
      return undefined;
    }
    const innerLen = UKEY2Handshake.readDerLen(der, offset + 1);
    if (innerLen.lenBytes === 0) {
      return undefined;
    }
    offset = offset + 2 + innerLen.lenBytes;
    for (let i = 0; i < 2; i++) {
      if (offset >= der.length || der[offset] !== 0x06) {
        return undefined;
      }
      const oidLen = UKEY2Handshake.readDerLen(der, offset + 1);
      offset = offset + 2 + oidLen.lenBytes + oidLen.value;
    }
    if (offset >= der.length || der[offset] !== 0x03) {
      return undefined;
    }
    const bitLen = UKEY2Handshake.readDerLen(der, offset + 1);
    offset = offset + 2 + bitLen.lenBytes;
    if (der[offset] !== 0x00) {
      return undefined;
    }
    offset += 1;
    if (der[offset] !== 0x04) {
      return undefined;
    }
    offset += 1;
    if (offset + 64 > der.length) {
      return undefined;
    }
    return {
      x: der.slice(offset, offset + 32),
      y: der.slice(offset + 32, offset + 64)
    };
  }

  private static readDerLen(der: Uint8Array, start: number): DerLen {
    if (start >= der.length || start < 0) {
      return { lenBytes: 0, value: 0 };
    }
    const first = der[start];
    if ((first & 0x80) === 0) {
      return { lenBytes: 1, value: first };
    }
    const count = first & 0x7f;
    if (count === 0 || count > 4 || start + 1 + count > der.length) {
      return { lenBytes: 0, value: 0 };
    }
    let value = 0;
    for (let i = 0; i < count; i++) {
      value = value * 256 + der[start + 1 + i];
    }
    return { lenBytes: count + 1, value };
  }

  private static equal(left: Uint8Array, right: Uint8Array): boolean {
    if (left.length !== right.length) {
      return false;
    }
    let diff = 0;
    for (let i = 0; i < left.length; i++) {
      diff |= left[i] ^ right[i];
    }
    return diff === 0;
  }
}
