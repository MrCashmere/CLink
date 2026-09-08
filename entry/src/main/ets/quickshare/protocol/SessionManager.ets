import { QuickShareEventEmitter } from '../utils/EventEmitter';
import { QuickShareSession, QuickShareSessionState } from './Session';
import { QuickShareSessionEvent } from './SessionEvent';

export class QuickShareSessionManager {
  readonly events: QuickShareEventEmitter<QuickShareSessionEvent> = new QuickShareEventEmitter<QuickShareSessionEvent>();
  private readonly sessions: Map<string, QuickShareSession> = new Map<string, QuickShareSession>();
  create(id: string): QuickShareSession { const session = new QuickShareSession(id); this.sessions.set(id, session); this.events.emit({ type: 'created', session }); return session; }
  get(id: string): QuickShareSession | undefined { return this.sessions.get(id); }
  transition(id: string, next: QuickShareSessionState): void { const session = this.sessions.get(id); if (session !== undefined) { session.move(next); this.events.emit({ type: next, session }); } }
}
