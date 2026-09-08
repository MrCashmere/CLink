export type QuickShareSessionState = 'DISCOVERED' | 'CONNECTING' | 'AUTHENTICATED' | 'CONNECTED' | 'TRANSFERRING' | 'COMPLETE' | 'FAILED';

export class QuickShareSession {
  state: QuickShareSessionState = 'DISCOVERED';
  constructor(readonly id: string) {}
  move(next: QuickShareSessionState): void { this.state = next; }
}
