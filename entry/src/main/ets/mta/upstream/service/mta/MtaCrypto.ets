/**
 * MtaCrypto.ets — MTA 凭据加解密
 *
 * 封装 @kit.CryptoArchitectureKit 的 ECDH P-256 密钥协商与 AES-256-CTR 解密：
 * 生成/持有本会话密钥对、导出 Base64(X.509 SPKI DER) 公钥、用对端公钥协商共享密钥、
 * 对 P2pInfo 中 Base64 编码的 ssid/psk/mac 单字段独立解密。
 * 协议参数（曲线、IV、AES 模式）统一取自 MtaConstants。
 */

import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { MtaConstants } from './MtaConstants';
import { DecryptedCredentials, DeviceInfoJson, P2pInfoJson } from '../../model/mta/MtaProtocolModels';
import { EncryptedCredentials } from '../../model/mta/MtaSendModels';
import { getLogger } from '../../utils/Logger';
import { LogDomains } from '../../common/LogDomains';
import { errorText } from '../../utils/FormatUtil';

const logger = getLogger(LogDomains.MTA, 'HandySend:MtaCrypto', '互传加密');

/** 字节数组转小写十六进制字符串 */
function bytesToHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    let h = bytes[i].toString(16);
    out += h.length === 1 ? '0' + h : h;
  }
  return out;
}

export class MtaCrypto {
  /** 本会话 ECDH 密钥对（每轮会话重新生成） */
  private keyPair: cryptoFramework.KeyPair | null = null;
  /** 本会话公钥 Base64（SPKI DER） */
  private publicKeyBase64: string = '';

  /** 是否已生成本会话密钥对 */
  hasKeyPair(): boolean {
    return this.keyPair !== null;
  }

  /** 本会话公钥 Base64（未生成时为空字符串） */
  getPublicKeyBase64(): string {
    return this.publicKeyBase64;
  }

  /**
   * 生成 ECDH P-256 密钥对并返回 Base64(X.509 SPKI DER) 公钥。
   * getEncoded() 返回的即为标准 SPKI DER，无需格式转换。
   */
  async generateKeyPair(): Promise<string> {
    let generator = cryptoFramework.createAsyKeyGenerator(MtaConstants.ECC_ALGORITHM);
    let keyPair = await generator.generateKeyPair();
    let encoded = keyPair.pubKey.getEncoded();
    this.keyPair = keyPair;
    this.publicKeyBase64 = new util.Base64Helper().encodeToStringSync(encoded.data, util.Type.BASIC);
    return this.publicKeyBase64;
  }

  /** 用对端 Base64 公钥协商共享密钥，返回 32 字节原始数据 */
  async deriveSharedKey(peerPublicKeyBase64: string): Promise<Uint8Array> {
    let keyPair = this.keyPair;
    if (keyPair === null) {
      logger.debug('共享密钥派生失败 阶段=本端密钥对未生成');
      throw new Error('本端 ECDH 密钥对尚未生成');
    }
    let peerBytes: Uint8Array;
    try {
      peerBytes = new util.Base64Helper().decodeSync(peerPublicKeyBase64, util.Type.BASIC);
    } catch (e) {
      logger.debug(
        `共享密钥派生失败 阶段=对端公钥Base64解码 原文长度=${peerPublicKeyBase64.length}` + ` 原因=${errorText(e)}`);
      throw new Error(errorText(e));
    }
    let peerPubBlob: cryptoFramework.DataBlob = { data: peerBytes };
    let generator = cryptoFramework.createAsyKeyGenerator(MtaConstants.ECC_ALGORITHM);
    try {
      // 仅传入对端公钥，私钥传 null（API 10+ 支持单边解析）
      let peerPair = await generator.convertKey(peerPubBlob, null);
      let agreement = cryptoFramework.createKeyAgreement(MtaConstants.ECC_ALGORITHM);
      let secret = await agreement.generateSecret(keyPair.priKey, peerPair.pubKey);
      logger.debug(
        `共享密钥派生成功 方式=ECDH P-256 密钥长度=${secret.data.length}` + ` 对端公钥字节=${peerBytes.length}`);
      return secret.data;
    } catch (e) {
      logger.debug(`共享密钥派生失败 阶段=密钥协商 对端公钥字节=${peerBytes.length}` + ` 原因=${errorText(e)}`);
      throw new Error(errorText(e));
    }
  }

  /** AES-256-CTR 解密单个 Base64 字段，返回 UTF-8 明文 */
  decryptBase64Field(sharedKey: Uint8Array, cipherBase64: string): string {
    let cipherBytes: Uint8Array;
    try {
      cipherBytes = new util.Base64Helper().decodeSync(cipherBase64, util.Type.BASIC);
    } catch (e) {
      logger.debug(`字段解密失败 阶段=Base64解码 密文Base64长度=${cipherBase64.length}` + ` 原因=${errorText(e)}`);
      throw new Error(errorText(e));
    }
    let ivBytes = MtaConstants.aesIvBytes();
    let ivHex = bytesToHex(ivBytes);
    let keyBlob: cryptoFramework.DataBlob = { data: sharedKey };
    let symGenerator = cryptoFramework.createSymKeyGenerator(MtaConstants.AES_SYM_ALGORITHM);
    let symKey = symGenerator.convertKeySync(keyBlob);
    let ivBlob: cryptoFramework.DataBlob = { data: ivBytes };
    let params: cryptoFramework.IvParamsSpec = {
      iv: ivBlob,
      algName: 'IvParamsSpec'
    };
    let cipher = cryptoFramework.createCipher(MtaConstants.AES_ALGORITHM);
    try {
      cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, params);
      let plainBlob = cipher.doFinalSync({ data: cipherBytes });
      logger.debug(`字段解密成功 IV=${ivHex} 密文长度=${cipherBytes.length}` + ` 明文长度=${plainBlob.data.length}`);
      return new util.TextDecoder().decodeToString(plainBlob.data);
    } catch (e) {
      logger.debug(`字段解密失败 阶段=AES解密 IV=${ivHex} 密文长度=${cipherBytes.length}` + ` 原因=${errorText(e)}`);
      throw new Error(errorText(e));
    }
  }

  /** AES-256-CTR 加密单个明文字段，返回 Base64 密文（与 decryptBase64Field 对称） */
  encryptBase64Field(sharedKey: Uint8Array, plain: string): string {
    let ivBytes = MtaConstants.aesIvBytes();
    let ivHex = bytesToHex(ivBytes);
    let plainBytes = new util.TextEncoder().encodeInto(plain);
    let keyBlob: cryptoFramework.DataBlob = { data: sharedKey };
    let symGenerator = cryptoFramework.createSymKeyGenerator(MtaConstants.AES_SYM_ALGORITHM);
    let symKey = symGenerator.convertKeySync(keyBlob);
    let ivBlob: cryptoFramework.DataBlob = { data: ivBytes };
    let params: cryptoFramework.IvParamsSpec = {
      iv: ivBlob,
      algName: 'IvParamsSpec'
    };
    let cipher = cryptoFramework.createCipher(MtaConstants.AES_ALGORITHM);
    try {
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, params);
      let cipherBlob = cipher.doFinalSync({ data: plainBytes });
      let result = new util.Base64Helper().encodeToStringSync(cipherBlob.data, util.Type.BASIC);
      logger.debug(`字段加密成功 IV=${ivHex} 明文长度=${plainBytes.length}` +
        ` 密文Base64长度=${result.length}`);
      return result;
    } catch (e) {
      logger.debug(`字段加密失败 阶段=AES加密 IV=${ivHex} 明文长度=${plainBytes.length}` + ` 原因=${errorText(e)}`);
      throw new Error(errorText(e));
    }
  }

  /**
   * 按协议加密本机 P2P 凭据：
   * - 对端 key 存在且非空：协商共享密钥后 AES-CTR 加密 ssid/psk/mac；
   * - key 缺失：按明文处理（与接收端解密对称）。
   */
  async encryptCredentials(info: DeviceInfoJson, credentials: DecryptedCredentials): Promise<EncryptedCredentials> {
    let result = new EncryptedCredentials();
    if (info.key.length === 0) {
      result.ssid = credentials.ssid;
      result.psk = credentials.psk;
      result.mac = credentials.mac;
      return result;
    }
    let sharedKey = await this.deriveSharedKey(info.key);
    result.ssid = this.encryptBase64Field(sharedKey, credentials.ssid);
    result.psk = this.encryptBase64Field(sharedKey, credentials.psk);
    result.mac = this.encryptBase64Field(sharedKey, credentials.mac);
    return result;
  }

  /**
   * 按协议解密 P2pInfo 凭据：
   * - key 存在且非空：协商共享密钥后 AES-CTR 解密 ssid/psk/mac；
   * - key 缺失：按明文处理，不报错。
   */
  async decryptCredentials(info: P2pInfoJson): Promise<DecryptedCredentials> {
    let credentials = new DecryptedCredentials();
    if (info.key.length === 0) {
      credentials.ssid = info.ssid;
      credentials.psk = info.psk;
      credentials.mac = info.mac;
      return credentials;
    }
    let sharedKey = await this.deriveSharedKey(info.key);
    credentials.ssid = this.decryptBase64Field(sharedKey, info.ssid);
    credentials.psk = this.decryptBase64Field(sharedKey, info.psk);
    credentials.mac = this.decryptBase64Field(sharedKey, info.mac);
    return credentials;
  }

  /** 清空本会话密钥对（服务复位时调用） */
  reset(): void {
    this.keyPair = null;
    this.publicKeyBase64 = '';
  }
}
