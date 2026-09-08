import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { GsBytes } from '../util/GsBytes';
import { ProtoWire } from './ProtoWire';
import { ProtoReader } from './ProtoReader';

export interface SecureKeys { enc: Uint8Array; sig: Uint8Array; }
export class SecureMessage {
  static async hmac(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> { const gen = cryptoFramework.createSymKeyGenerator('HMAC'); const sk = await gen.convertKey({ data: key }); const spec: cryptoFramework.HmacSpec = { algName: 'HMAC', mdName: 'SHA256' }; const mac = cryptoFramework.createMac(spec); await mac.init(sk); await mac.update({ data }); return new Uint8Array((await mac.doFinal()).data); }
  static async seal(keys: SecureKeys, body: Uint8Array, sequence: number): Promise<Uint8Array> {
    const random = cryptoFramework.createRandom(); const iv = new Uint8Array((await random.generateRandom(16)).data);
    const gen = cryptoFramework.createSymKeyGenerator('AES256'); const sk = await gen.convertKey({ data: keys.enc }); const cipher = cryptoFramework.createCipher('AES256|CBC|PKCS7');
    const params: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: { data: iv } }; await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, sk, params); const encrypted = new Uint8Array((await cipher.doFinal({ data: body })).data);
    // Header per securemessage.proto: signature_scheme=1, encryption_scheme=2,
    // iv=5, public_metadata=6. Android requires public_metadata to carry the
    // GcmMetadata{type=DEVICE_TO_DEVICE_MESSAGE(13), version=1} tag; without it
    // it throws SignatureException "missing metadata" when decrypting our frames.
    const publicMetadata: Uint8Array = ProtoWire.message([ProtoWire.fieldEnum(1, 13), ProtoWire.fieldInt32(2, 1)]);
    const header = ProtoWire.message([ProtoWire.fieldEnum(1, 1), ProtoWire.fieldEnum(2, 2), ProtoWire.fieldBytes(5, iv), ProtoWire.fieldBytes(6, publicMetadata)]);
    const headerAndBody = ProtoWire.message([ProtoWire.fieldBytes(1, header), ProtoWire.fieldBytes(2, encrypted)]);
    const signature = await SecureMessage.hmac(keys.sig, headerAndBody);
    return ProtoWire.message([ProtoWire.fieldBytes(1, headerAndBody), ProtoWire.fieldBytes(2, signature)]);
  }
  static async open(keys: SecureKeys, packet: Uint8Array, sequence: number): Promise<Uint8Array> {
    const headerAndBody: Uint8Array | undefined = ProtoReader.firstBytes(packet, 1); const signature: Uint8Array | undefined = ProtoReader.firstBytes(packet, 2);
    if (headerAndBody === undefined || signature === undefined) throw new Error('invalid SecureMessage');
    const expected: Uint8Array = await SecureMessage.hmac(keys.sig, headerAndBody); if (!SecureMessage.equal(expected, signature)) throw new Error('SecureMessage HMAC verification failed');
    const header: Uint8Array | undefined = ProtoReader.firstBytes(headerAndBody, 1); const encrypted: Uint8Array | undefined = ProtoReader.firstBytes(headerAndBody, 2); if (header === undefined || encrypted === undefined) throw new Error('invalid HeaderAndBody');
    if ((ProtoReader.firstVarint(header, 1) ?? 0) !== 1 || (ProtoReader.firstVarint(header, 2) ?? 0) !== 2) throw new Error('unsupported SecureMessage algorithms');
    const iv: Uint8Array | undefined = ProtoReader.firstBytes(header, 5); if (iv === undefined || iv.length !== 16) throw new Error('invalid SecureMessage IV');
    const gen = cryptoFramework.createSymKeyGenerator('AES256'); const sk = await gen.convertKey({ data: keys.enc }); const cipher = cryptoFramework.createCipher('AES256|CBC|PKCS7'); const params: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: { data: iv } }; await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, sk, params); return new Uint8Array((await cipher.doFinal({ data: encrypted })).data);
  }
  static equal(left: Uint8Array, right: Uint8Array): boolean { if (left.length !== right.length) return false; let diff: number = 0; for (let i = 0; i < left.length; i++) diff |= left[i] ^ right[i]; return diff === 0; }
}
