export class QuickShareTransferReceiver {
  private readonly parts: Uint8Array[] = [];
  add(part: Uint8Array): void { this.parts.push(part); }
  assemble(): Uint8Array { const size = this.parts.reduce((total: number, part: Uint8Array): number => total + part.length, 0); const result = new Uint8Array(size); let offset = 0; this.parts.forEach((part: Uint8Array): void => { result.set(part, offset); offset += part.length; }); return result; }
}
