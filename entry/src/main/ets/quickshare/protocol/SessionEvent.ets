import { QuickShareSession } from './Session';
export interface QuickShareSessionEvent { readonly type: string; readonly session: QuickShareSession; readonly error?: string; }
