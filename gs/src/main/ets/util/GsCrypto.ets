import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { GsBytes } from './GsBytes';

export class GsCrypto {
  static createPin(): string {
    const value = Math.floor(1000 + Math.random() * 9000);
    return value.toString();
  }

  static createToken(): string {
    return util.generateRandomUUID().replace(/-/g, '');
  }

  static async randomBytes(length: number): Promise<Uint8Array> {
    const random = cryptoFramework.createRandom();
    const blob = await random.generateRandom(length);
    return new Uint8Array(blob.data);
  }

  static async sha256(input: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: input });
    const digest = await md.digest();
    return new Uint8Array(digest.data);
  }

  static async sha256Hex(input: Uint8Array): Promise<string> {
    return GsBytes.toHex(await GsCrypto.sha256(input));
  }

  static async sha512(input: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA512');
    await md.update({ data: input });
    const digest = await md.digest();
    return new Uint8Array(digest.data);
  }

  /**
   * HKDF-SHA256 (EXTRACT_AND_EXPAND). Used to mirror the Quick Share
   * post-handshake "authString" derivation so the PIN seed follows the same
   * salt semantics ("UKEY2 v1 auth").
   */
  static async hkdfSha256(key: Uint8Array, salt: Uint8Array, info: Uint8Array, lengthBytes: number): Promise<Uint8Array> {
    const kdf = cryptoFramework.createKdf('HKDF|SHA256');
    const spec: cryptoFramework.HKDFSpec = {
      algName: 'HKDF',
      key,
      salt,
      info,
      keySize: lengthBytes
    };
    const material = await kdf.generateSecret(spec);
    return new Uint8Array(material.data).slice(0, lengthBytes);
  }

  /**
   * Derives the 4-digit Quick Share confirmation PIN — bit-exact with the
   * open-source reference implementation (ported from NearDrop
   * `pinCodeFromAuthKey` / Chromium):
   *
   *     hash = 0; multiplier = 1
   *     for each byte b (interpreted as SIGNED):
   *         hash      = (hash + b * multiplier) % 9973
   *         multiplier = (multiplier * 31) % 9973
   *     pin = abs(hash) zero-padded to 4 digits
   *
   * The signed-byte interpretation and truncated `%` are load-bearing: bytes
   * >= 0x80 must contribute negative values, exactly like Swift `Int8` /
   * Kotlin `Byte.toInt()`.
   */
  static pinFromBytes(bytes: Uint8Array): string {
    const modulus = 9973;
    let hash = 0;
    let multiplier = 1;
    for (let i = 0; i < bytes.length; i++) {
      const signed = bytes[i] >= 128 ? bytes[i] - 256 : bytes[i];
      hash = (hash + signed * multiplier) % modulus;
      multiplier = (multiplier * 31) % modulus;
    }
    return Math.abs(hash).toString().padStart(4, '0');
  }
}
