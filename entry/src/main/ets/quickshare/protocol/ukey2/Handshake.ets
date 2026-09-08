export type QuickShareUkey2State = 'Idle' | 'ClientInit' | 'ServerInit' | 'ClientFinish' | 'Established';
export interface QuickShareHandshakeMessage { readonly type: 'ClientInit' | 'ServerInit' | 'ClientFinish'; readonly payload: Uint8Array; }
