import { fileIo as fs } from '@kit.CoreFileKit';
let textDirectory: string = '';
export function configureMtaTextDirectory(directory: string): void { textDirectory = directory; }
export function recvTextDir(): string { return textDirectory; }
export function uniquePath(directory: string, name: string): string {
  const dot = name.lastIndexOf('.');
  const base = dot > 0 ? name.slice(0, dot) : name;
  const ext = dot > 0 ? name.slice(dot) : '';
  let candidate = name;
  let index = 1;
  while (fs.accessSync(directory + '/' + candidate)) { candidate = base + ' (' + index++ + ')' + ext; }
  return candidate;
}
