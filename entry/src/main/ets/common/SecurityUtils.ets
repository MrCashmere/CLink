import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { ByteUtils } from './ByteUtils';

export class SecurityUtils {
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
    return ByteUtils.toHex(await SecurityUtils.sha256(input));
  }

  static async keyedHash(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    return SecurityUtils.sha256(ByteUtils.concat([key, data]));
  }

  static pinFromBytes(bytes: Uint8Array): string {
    let value = 7;
    for (let i = 0; i < 8 && i < bytes.length; i++) {
      value = (value * 251 + bytes[i]) % 100000007;
    }
    return (value % 10000).toString().padStart(4, '0');
  }
}