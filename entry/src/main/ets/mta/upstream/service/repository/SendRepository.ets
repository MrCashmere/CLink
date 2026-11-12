let textDirectory: string = '';
let thumbnailDirectory: string = '';
export function sendTextDir(): string { return textDirectory; }
export function sendThumbnailDir(): string { return thumbnailDirectory; }
export function configureMtaSendDirs(text: string, thumbnail: string): void {
  textDirectory = text.endsWith('/') ? text : text + '/';
  thumbnailDirectory = thumbnail.endsWith('/') ? thumbnail : thumbnail + '/';
}
