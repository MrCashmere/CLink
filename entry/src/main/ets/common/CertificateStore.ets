import { LogCapture as Lg } from '../common/LogCapture';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ByteUtils } from './ByteUtils';
import { SecurityUtils } from './SecurityUtils';

export interface TlsMaterial {
  readonly certPath: string;
  readonly keyPath: string;
}

const CERT_RAW_NAME = 'cashmere_cert.pem';
const KEY_RAW_NAME = 'cashmere_key.pem';

export class CertificateStore {
  private material?: TlsMaterial;

  private readonly context: common.Context;

  constructor(context: common.Context) {
    this.context = context;
  }

  async ensure(): Promise<TlsMaterial | undefined> {
    if (this.material !== undefined) {
      return this.material;
    }
    try {
      const dir = `${this.context.filesDir}/tls`;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      const certPath = `${dir}/${CERT_RAW_NAME}`;
      const keyPath = `${dir}/${KEY_RAW_NAME}`;
      if (!fs.accessSync(certPath)) {
        await this.copyRawFile(CERT_RAW_NAME, certPath);
      }
      if (!fs.accessSync(keyPath)) {
        await this.copyRawFile(KEY_RAW_NAME, keyPath);
      }
      this.material = { certPath, keyPath };
      return this.material;
    } catch (error) {
      Lg.w(`CertificateStore ensure failed: ${JSON.stringify(error)}`);
      return undefined;
    }
  }

  async fingerprint(): Promise<string> {
    try {
      const material = await this.ensure();
      if (material === undefined) {
        return '';
      }
      const pem = await fs.readText(material.certPath);
      const base64Text = pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
      const base64 = new util.Base64Helper();
      const der = new Uint8Array(base64.decodeSync(base64Text));
      return (await SecurityUtils.sha256Hex(der)).toUpperCase();
    } catch (error) {
      Lg.w('CertificateStore fingerprint failed: ' + JSON.stringify(error));
      return '';
    }
  }

  private async copyRawFile(rawName: string, target: string): Promise<void> {
    const content = await this.context.resourceManager.getRawFileContent(rawName);
    const file = fs.openSync(target, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      await fs.write(file.fd, ByteUtils.toArrayBuffer(content));
    } finally {
      fs.closeSync(file);
    }
  }
}