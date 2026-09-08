/**
 * MS-CDP session encryption (CdpCryptor.cs).
 *
 * The 64-byte shared secret is split:
 *   [0:16]   AES-128-CBC message key
 *   [16:32]  AES-128-CBC IV-generation key
 *   [32:64]  HMAC-SHA256 key
 *
 * Each message is encrypted as:
 *   plaintext = [u32BE payloadLength][payload]
 *   (PKCS7 only when plaintext length is NOT a multiple of 16)
 *   IV = AES-CBC(IVKey, sessionId+seq+fragIndex+fragCount block, zero IV, NoPadding)
 *   frame = [CommonHeader][AES-CBC ciphertext][HMAC-SHA256]
 *
 * Decryption reverses the HMAC over the header (with MessageLength minus HMAC)
 * concatenated with the ciphertext, then slices the real payload via the
 * leading u32BE length.
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { ByteUtils } from '../../common/ByteUtils';
import {
  CdpAdditionalHeader,
  CdpCommonHeader,
  CdpWriter,
  CDP_HMAC_SIZE,
  CDP_IV_SIZE,
  CdpMessageFlags
} from './CdpCodec';

const AES_BLOCK = 16;
const AES_KEY = 'AES128|CBC|NoPadding';

export class CdpCryptor {
  private readonly aesKey: Uint8Array;
  private readonly ivKey: Uint8Array;
  private readonly hmacKey: Uint8Array;

  constructor(sharedSecret: Uint8Array) {
    if (sharedSecret.length !== 64) {
      throw new Error('CDP shared secret must be 64 bytes, got ' + sharedSecret.length);
    }
    this.aesKey = sharedSecret.slice(0, 16);
    this.ivKey = sharedSecret.slice(16, 32);
    this.hmacKey = sharedSecret.slice(32, 64);
  }

  /** Encrypt a message payload (the header is copied and mutated). */
  async encryptMessage(header: CdpCommonHeader, payload: Uint8Array): Promise<Uint8Array> {
    const plaintext = ByteUtils.concat([ByteUtils.writeU32BE(payload.length), payload]);
    const withPadding = CdpCryptor.applyPadding(plaintext);

    header.setFlag(CdpMessageFlags.SessionEncrypted);
    header.setFlag(CdpMessageFlags.HasHMAC);

    const iv = await this.generateIV(header);
    const ciphertext = await this.cipher(this.aesKey, iv, withPadding, true);

    // Header (MessageLength = header + ciphertext) used for the HMAC.
    const headerNoHmac = this.cloneHeader(header, ciphertext.length);
    const headerBytesNoHmac = this.serializeHeader(headerNoHmac);
    const hmacInput = ByteUtils.concat([headerBytesNoHmac, ciphertext]);
    const hmac = await this.hmac(hmacInput);

    // Final header: MessageLength = header + ciphertext + HMAC.
    const headerFinal = this.cloneHeader(header, ciphertext.length + CDP_HMAC_SIZE);
    const headerBytesFinal = this.serializeHeader(headerFinal);

    return ByteUtils.concat([headerBytesFinal, ciphertext, hmac]);
  }

  /** Decrypt a full frame, returning the real payload (without the length prefix). */
  async decryptFrame(frame: Uint8Array, header: CdpCommonHeader): Promise<Uint8Array> {
    const headerSize = header.calcSize();
    const payloadSize = header.payloadSize();
    const hasHmac = header.hasFlag(CdpMessageFlags.HasHMAC);
    let ciphertextLen = payloadSize;
    if (hasHmac) {
      ciphertextLen -= CDP_HMAC_SIZE;
    }
    if (ciphertextLen < 0) {
      throw new Error('CDP invalid encrypted frame: negative ciphertext length');
    }
    const ciphertext = frame.slice(headerSize, headerSize + ciphertextLen);
    if (hasHmac) {
      const hmac = frame.slice(headerSize + ciphertextLen, headerSize + ciphertextLen + CDP_HMAC_SIZE);
      const headerNoHmac = this.cloneHeader(header, ciphertextLen);
      const headerBytesNoHmac = this.serializeHeader(headerNoHmac);
      const expected = await this.hmac(ByteUtils.concat([headerBytesNoHmac, ciphertext]));
      if (!CdpCryptor.equal(expected, hmac)) {
        throw new Error('CDP HMAC verification failed');
      }
    }

    const iv = await this.generateIV(header);
    const decryptedWithPad = await this.cipher(this.aesKey, iv, ciphertext, false);
    if (decryptedWithPad.length < 4) {
      throw new Error('CDP decrypted payload too short');
    }
    const payloadLength = ByteUtils.readU32BE(decryptedWithPad, 0);
    if (payloadLength + 4 > decryptedWithPad.length) {
      throw new Error('CDP decrypted payload length exceeds block data');
    }
    return decryptedWithPad.slice(4, 4 + payloadLength);
  }

  /** Deterministic IV: AES-CBC(IVKey, sessionInfo, zero IV, NoPadding). */
  private async generateIV(header: CdpCommonHeader): Promise<Uint8Array> {
    const block = new Uint8Array(CDP_IV_SIZE);
    block.set(header.sessionId, 0);
    block[8] = (header.sequenceNumber >>> 24) & 0xff;
    block[9] = (header.sequenceNumber >>> 16) & 0xff;
    block[10] = (header.sequenceNumber >>> 8) & 0xff;
    block[11] = header.sequenceNumber & 0xff;
    block[12] = (header.fragmentIndex >>> 8) & 0xff;
    block[13] = header.fragmentIndex & 0xff;
    block[14] = (header.fragmentCount >>> 8) & 0xff;
    block[15] = header.fragmentCount & 0xff;
    const iv = await this.cipher(this.ivKey, new Uint8Array(AES_BLOCK), block, true);
    return iv;
  }

  private async cipher(key: Uint8Array, iv: Uint8Array, input: Uint8Array, encrypt: boolean): Promise<Uint8Array> {
    const gen = cryptoFramework.createSymKeyGenerator('AES128');
    const sk = await gen.convertKey({ data: key });
    const cipher = cryptoFramework.createCipher(AES_KEY);
    const params: cryptoFramework.IvParamsSpec = { algName: 'IvParamsSpec', iv: { data: iv } };
    const mode = encrypt ? cryptoFramework.CryptoMode.ENCRYPT_MODE : cryptoFramework.CryptoMode.DECRYPT_MODE;
    await cipher.init(mode, sk, params);
    const result = await cipher.doFinal({ data: input });
    return new Uint8Array(result.data);
  }

  private async hmac(data: Uint8Array): Promise<Uint8Array> {
    const gen = cryptoFramework.createSymKeyGenerator('HMAC');
    const sk = await gen.convertKey({ data: this.hmacKey });
    const mac = cryptoFramework.createMac('SHA256');
    await mac.init(sk);
    await mac.update({ data });
    const result = await mac.doFinal();
    return new Uint8Array(result.data);
  }

  private cloneHeader(header: CdpCommonHeader, ciphertextAndHmacLen: number): CdpCommonHeader {
    const copy = new CdpCommonHeader();
    copy.version = header.version;
    copy.type = header.type;
    copy.flags = header.flags;
    copy.sequenceNumber = header.sequenceNumber;
    copy.requestId = header.requestId.slice();
    copy.fragmentIndex = header.fragmentIndex;
    copy.fragmentCount = header.fragmentCount;
    copy.sessionId = header.sessionId.slice();
    copy.channelId = header.channelId.slice();
    copy.additionalHeaders = header.additionalHeaders.map((additional: CdpAdditionalHeader): CdpAdditionalHeader =>
      new CdpAdditionalHeader(additional.type, additional.value));
    copy.setPayloadLength(ciphertextAndHmacLen);
    return copy;
  }

  private serializeHeader(header: CdpCommonHeader): Uint8Array {
    const writer = new CdpWriter();
    writer.writeHeader(header);
    return writer.finish();
  }

  private static applyPadding(input: Uint8Array): Uint8Array {
    const remainder = input.length % AES_BLOCK;
    if (remainder === 0) {
      return input;
    }
    const padding = AES_BLOCK - remainder;
    const padded = new Uint8Array(input.length + padding);
    padded.set(input);
    for (let i = input.length; i < padded.length; i++) {
      padded[i] = padding;
    }
    return padded;
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
