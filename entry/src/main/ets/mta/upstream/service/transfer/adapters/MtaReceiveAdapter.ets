import { MediaFileInfo } from '../../../model/Types';
import { ReceiverState, ReceivedFileEntry } from '../../../model/mta/MtaProtocolModels';

export interface MtaReceiveStorageHooks {
  receiveDirectory: (original: string) => string;
  finishReceived: (paths: string[], files: ReceivedFileEntry[]) => Promise<string[]>;
}
let storageHooks: MtaReceiveStorageHooks | undefined = undefined;
export function mtaReceiveDirectory(original: string): string {
  return storageHooks !== undefined ? storageHooks.receiveDirectory(original) : original;
}
export async function finalizeMtaReceivedFiles(paths: string[], files: ReceivedFileEntry[]): Promise<string[]> {
  return storageHooks !== undefined ? await storageHooks.finishReceived(paths, files) : paths;
}

let stateHandler: ((state: ReceiverState) => void) | undefined = undefined;
let textHandler: ((savedPath: string) => void) | undefined = undefined;
let acceptFiles: () => void = (): void => {};
let reject: () => void = (): void => {};
let cancel: () => void = (): void => {};
let acceptText: () => void = (): void => {};
export function configureMtaReceiveHost(onState: (state: ReceiverState) => void,
  onTextSaved: (savedPath: string) => void, storage?: MtaReceiveStorageHooks): void {
  stateHandler = onState; textHandler = onTextSaved; storageHooks = storage;
}
export function handleMtaReceiveState(state: ReceiverState): void { stateHandler?.(state); }
export function notifyMtaTextSaved(savedPath: string): void { textHandler?.(savedPath); }
export function setMtaReceiveInvokers(files: () => void, decline: () => void,
  stop: () => void, text: () => void, media: () => MediaFileInfo[]): void {
  acceptFiles = files; reject = decline; cancel = stop; acceptText = text;
}
export function acceptMtaHostRequest(text: boolean): void { if (text) { acceptText(); } else { acceptFiles(); } }
export function rejectMtaHostRequest(): void { reject(); }
export function cancelMtaHostReceive(): void { cancel(); }
