import { LogCapture as Lg } from '../common/LogCapture';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { ByteUtils } from './ByteUtils';
import { SecurityUtils } from './SecurityUtils';
import { nativeGenerateTlsIdentity } from 'libmta_core.so';
import { DeviceIdentity } from './DeviceIdentity';

export interface TlsMaterial {
  readonly certPath: string;
  readonly keyPath: string;
}


interface GeneratedTlsIdentity {
  certificatePem: string;
  privateKeyPem: string;
}

export class CertificateStore {
  private static readonly inFlight: Map<string, Promise<TlsMaterial | undefined>> =
    new Map<string, Promise<TlsMaterial | undefined>>();
  private material?: TlsMaterial;
  private readonly context: common.Context;

  constructor(context: common.Context) { this.context = context; }

  async ensure(): Promise<TlsMaterial | undefined> {
    if (this.material !== undefined) { return this.material; }
    const root: string = this.context.filesDir;
    let operation: Promise<TlsMaterial | undefined> | undefined = CertificateStore.inFlight.get(root);
    if (operation === undefined) {
      operation = CertificateStore.ensureInDirectory(root);
      CertificateStore.inFlight.set(root, operation);
    }
    try {
      this.material = await operation;
      return this.material;
    } finally {
      if (CertificateStore.inFlight.get(root) === operation) { CertificateStore.inFlight.delete(root); }
    }
  }

  private static async ensureInDirectory(root: string): Promise<TlsMaterial | undefined> {
    // The legacy /tls pair came from the app bundle and was identical on every device.
    const directory: string = root + '/tls-device-v2';
    const certPath: string = directory + '/cert.pem';
    const keyPath: string = directory + '/key.pem';
    let temporary: string = '';
    try {
      if (fs.accessSync(certPath) && fs.accessSync(keyPath)
        && fs.statSync(certPath).size > 0 && fs.statSync(keyPath).size > 0) {
        return { certPath, keyPath };
      }
      const identity: GeneratedTlsIdentity = JSON.parse(await nativeGenerateTlsIdentity()) as GeneratedTlsIdentity;
      if (!identity.certificatePem.startsWith('-----BEGIN CERTIFICATE-----')
        || !identity.privateKeyPem.startsWith('-----BEGIN PRIVATE KEY-----')) {
        throw new Error('invalid generated TLS identity');
      }
      temporary = fs.mkdtempSync(root + '/tls-identity-XXXXXX');
      CertificateStore.writePem(temporary + '/cert.pem', identity.certificatePem);
      CertificateStore.writePem(temporary + '/key.pem', identity.privateKeyPem);
      if (fs.accessSync(directory)) { fs.rmdirSync(directory); }
      fs.renameSync(temporary, directory);
      temporary = '';
      return { certPath, keyPath };
    } catch (error) {
      Lg.w('CertificateStore identity setup failed: ' + String(error));
      return undefined;
    } finally {
      if (temporary.length > 0) {
        try { fs.rmdirSync(temporary); } catch (error) { Lg.w('CertificateStore temporary cleanup failed'); }
      }
    }
  }

  async discoveryFingerprint(https: boolean): Promise<string> {
    if (https) {
      const fingerprint: string = await this.fingerprint();
      if (fingerprint.length > 0) { return fingerprint; }
    }
    return await DeviceIdentity.load(this.context);
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

  private static writePem(path: string, pem: string): void {
    const bytes: Uint8Array = ByteUtils.encodeText(pem);
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      if (fs.writeSync(file.fd, ByteUtils.toArrayBuffer(bytes)) !== bytes.length) {
        throw new Error('could not persist TLS identity');
      }
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
  }
}
