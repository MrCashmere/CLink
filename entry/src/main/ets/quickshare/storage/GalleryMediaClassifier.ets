/**
 * 权威依据：用户 2026-11-07 接收媒体自动入图库需求；HarmonyOS 用户侧可见文案约束 1.0。
 * 本轮改动：集中判断收到的文件是否为可尝试写入图库的图片或视频。
 * 用户侧：本文件不产生任何界面文案。
 * 🔴 红线：非图片/视频必须返回 other；所有接收链路的媒体判型只能走这里。
 */

export type GalleryMediaKind = 'image' | 'video' | 'other';

export interface GalleryMediaClassification {
  readonly kind: GalleryMediaKind;
  readonly extension: string;
  readonly title: string;
}

const IMAGE_EXTENSIONS: string[] = [
  'jpg',
  'jpeg',
  'jpe',
  'png',
  'gif',
  'webp',
  'bmp',
  'heic',
  'heif',
  'hif',
  'avif',
  'tif',
  'tiff',
  'jxl',
  'dng'
];

const VIDEO_EXTENSIONS: string[] = [
  'mp4',
  'm4v',
  'mov',
  '3gp',
  '3g2',
  'mkv',
  'webm',
  'avi',
  'mts',
  'm2ts',
  'mpg',
  'mpeg',
  'wmv',
  'flv',
  'ogv'
  // 不把裸 ts 放进扩展名白名单：LocalSend 接收目录里的文本 TypeScript 文件
  // 可能没有 MIME，不能被误送进图库。只有显式 video/mp2t 才按视频处理。
];

const MAX_TITLE_LENGTH: number = 96;
const FALLBACK_TITLE: string = 'received-media';

export class GalleryMediaClassifier {
  /** 返回小写扩展名，不包含点；没有扩展名时返回空串。 */
  static extensionOf(name: string): string {
    const normalized: string = GalleryMediaClassifier.baseNameOf(name);
    const dot: number = normalized.lastIndexOf('.');
    if (dot <= 0 || dot >= normalized.length - 1) {
      return '';
    }
    return normalized.substring(dot + 1).toLowerCase();
  }

  /** 清洗后的完整文件名，用于下载回退和日志。 */
  static safeFileName(name: string): string {
    const base: string = GalleryMediaClassifier.baseNameOf(name);
    let output: string = '';
    for (let index = 0; index < base.length; index++) {
      const code: number = base.charCodeAt(index);
      const ch: string = base.charAt(index);
      if (code < 0x20 || code === 0x7f) {
        continue;
      }
      const safe: string = GalleryMediaClassifier.isInvalidFileNameCharacter(ch) ? '_' : ch;
      if (safe === '_' && output.endsWith('_')) {
        continue;
      }
      output += safe;
      if (output.length >= MAX_TITLE_LENGTH + 20) {
        break;
      }
    }
    const trimmed: string = output.trim().replace(/\.+$/, '');
    if (trimmed.length === 0 || trimmed === '.' || trimmed === '..') {
      return FALLBACK_TITLE;
    }
    return trimmed;
  }

  /** 返回可用于图库资产 title 的纯文件名主干（不含扩展名）。 */
  static titleOf(name: string): string {
    const safe: string = GalleryMediaClassifier.safeFileName(name);
    const dot: number = safe.lastIndexOf('.');
    const stem: string = dot > 0 ? safe.substring(0, dot) : safe;
    const trimmed: string = stem.trim().replace(/^\.+/, '');
    if (trimmed.length === 0 || trimmed === '.' || trimmed === '..') {
      return FALLBACK_TITLE;
    }
    return trimmed.length > MAX_TITLE_LENGTH ? trimmed.substring(0, MAX_TITLE_LENGTH) : trimmed;
  }

  static isImageExtension(extension: string): boolean {
    return IMAGE_EXTENSIONS.indexOf(extension.toLowerCase()) >= 0;
  }

  static isVideoExtension(extension: string): boolean {
    return VIDEO_EXTENSIONS.indexOf(extension.toLowerCase()) >= 0;
  }

  static isMediaName(name: string, mime: string = ''): boolean {
    return GalleryMediaClassifier.classify(name, mime).kind !== 'other';
  }

  static classify(name: string, mime: string = ''): GalleryMediaClassification {
    const extension: string = GalleryMediaClassifier.extensionOf(name);
    const title: string = GalleryMediaClassifier.titleOf(name);
    const normalizedMime: string = GalleryMediaClassifier.normalizeMime(mime);
    if (GalleryMediaClassifier.isClearlyNonMediaMime(normalizedMime)) {
      return { kind: 'other', extension: extension, title: title };
    }
    if (normalizedMime.startsWith('image/')) {
      let mimeExtension: string = GalleryMediaClassifier.extensionForMime(normalizedMime, 'image');
      if (mimeExtension.length === 0 && GalleryMediaClassifier.isImageExtension(extension)) {
        mimeExtension = extension;
      }
      const kind: GalleryMediaKind = mimeExtension.length > 0 ? 'image' : 'other';
      return { kind: kind, extension: mimeExtension, title: title };
    }
    if (normalizedMime.startsWith('video/')) {
      let mimeExtension: string = GalleryMediaClassifier.extensionForMime(normalizedMime, 'video');
      if (mimeExtension.length === 0 && GalleryMediaClassifier.isVideoExtension(extension)) {
        mimeExtension = extension;
      }
      const kind: GalleryMediaKind = mimeExtension.length > 0 ? 'video' : 'other';
      return { kind: kind, extension: mimeExtension, title: title };
    }
    if (GalleryMediaClassifier.isImageExtension(extension)) {
      return { kind: 'image', extension: extension, title: title };
    }
    if (GalleryMediaClassifier.isVideoExtension(extension)) {
      return { kind: 'video', extension: extension, title: title };
    }
    return { kind: 'other', extension: extension, title: title };
  }

  private static normalizeMime(mime: string): string {
    const semicolon: number = mime.indexOf(';');
    const base: string = semicolon >= 0 ? mime.substring(0, semicolon) : mime;
    return base.trim().toLowerCase();
  }

  private static isClearlyNonMediaMime(mime: string): boolean {
    return mime.startsWith('text/')
      || mime === 'application/pdf'
      || mime === 'application/zip'
      || mime === 'application/x-zip-compressed'
      || mime === 'application/json'
      || mime === 'application/javascript';
  }

  private static extensionForMime(mime: string, kind: GalleryMediaKind): string {
    switch (mime) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/gif':
        return 'gif';
      case 'image/webp':
        return 'webp';
      case 'image/bmp':
        return 'bmp';
      case 'image/heic':
        return 'heic';
      case 'image/heif':
        return 'heif';
      case 'image/avif':
        return 'avif';
      case 'image/tiff':
        return 'tiff';
      case 'image/jxl':
        return 'jxl';
      case 'image/x-adobe-dng':
        return 'dng';
      case 'video/mp4':
        return 'mp4';
      case 'video/x-m4v':
        return 'm4v';
      case 'video/quicktime':
        return 'mov';
      case 'video/3gpp':
        return '3gp';
      case 'video/3gpp2':
        return '3g2';
      case 'video/x-matroska':
        return 'mkv';
      case 'video/webm':
        return 'webm';
      case 'video/x-msvideo':
        return 'avi';
      case 'video/mp2t':
        return 'ts';
      case 'video/mpeg':
        return 'mpeg';
      case 'video/x-ms-wmv':
        return 'wmv';
      case 'video/x-flv':
        return 'flv';
      case 'video/ogg':
        return 'ogv';
      default:
        break;
    }
    const slash: number = mime.indexOf('/');
    const subtype: string = slash >= 0 ? mime.substring(slash + 1) : '';
    if (kind === 'image' && GalleryMediaClassifier.isImageExtension(subtype)) {
      return subtype;
    }
    if (kind === 'video' && GalleryMediaClassifier.isVideoExtension(subtype)) {
      return subtype;
    }
    return '';
  }

  private static baseNameOf(name: string): string {
    const slash: number = name.lastIndexOf('/');
    const backslash: number = name.lastIndexOf('\\');
    const index: number = Math.max(slash, backslash);
    return index >= 0 ? name.substring(index + 1) : name;
  }

  private static isInvalidFileNameCharacter(ch: string): boolean {
    return ch === '\\' || ch === '/' || ch === ':' || ch === '*' || ch === '?'
      || ch === '"' || ch === '<' || ch === '>' || ch === '|' || ch === '\''
      || ch === '`' || ch === '{' || ch === '}' || ch === '[' || ch === ']';
  }
}
