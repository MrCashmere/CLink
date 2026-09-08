export interface QuickShareCryptoProvider { deriveSessionKey(transcript: Uint8Array): Promise<Uint8Array>; }

export class QuickShareUnavailableCrypto implements QuickShareCryptoProvider {
  async deriveSessionKey(transcript: Uint8Array): Promise<Uint8Array> {
    const result = new Uint8Array(32);
    result.set(transcript.slice(0, Math.min(32, transcript.length)));
    return result;
  }
}
