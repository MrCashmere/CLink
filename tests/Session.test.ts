import { QuickShareSession } from '../entry/src/main/ets/quickshare/protocol/Session';
export function transitionsSession(): boolean { const session = new QuickShareSession('id'); session.move('CONNECTED'); return session.state === 'CONNECTED'; }
