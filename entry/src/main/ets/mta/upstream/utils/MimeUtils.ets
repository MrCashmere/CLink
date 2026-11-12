// MimeUtils：从 AppService 抽出的 MIME 类型工具函数

export function isImage(mime: string): boolean {
  return mime.startsWith('image/');
}

export function isVideo(mime: string): boolean {
  return mime.startsWith('video/');
}

// 是否为可保存到相册的媒体类型（图片或视频）；基于真实 MIME 判定，
// 作为「保存到相册」媒体筛选的唯一依据。
export function isMediaMime(mime: string): boolean {
  return isImage(mime) || isVideo(mime);
}

export function getMimeForExt(ext: string): string {
  let map: Record<string, string> = {
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'gif': 'image/gif',
    'bmp': 'image/bmp',
    'webp': 'image/webp',
    'svg': 'image/svg+xml',
    'heic': 'image/heic',
    'mp4': 'video/mp4',
    'avi': 'video/x-msvideo',
    'mkv': 'video/x-matroska',
    'mov': 'video/quicktime',
    'webm': 'video/webm',
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
    'ogg': 'audio/ogg',
    'flac': 'audio/flac',
    'aac': 'audio/aac',
    'm4a': 'audio/mp4',
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'wps': 'application/kswps',
    'et': 'application/kset',
    'dps': 'application/ksdps',
    'ofd': 'application/ofd',
    'pom': 'application/x-pom',
    'vsd': 'application/vnd.visio',
    'vsdx': 'application/vnd.ms-visio.drawing',
    'drawio': 'application/x-drawio',
    'eddx': 'application/x-eddx',
    'pos': 'application/x-pos',
    'xmind': 'application/x-xmind',
    'mm': 'application/x-freemind',
    'opml': 'text/x-opml',
    'zip': 'application/zip',
    'rar': 'application/vnd.rar',
    '7z': 'application/x-7z-compressed',
    'tar': 'application/x-tar',
    'gz': 'application/gzip',
    'txt': 'text/plain',
    'html': 'text/html',
    'css': 'text/css',
    'js': 'application/javascript',
    'json': 'application/json',
    'xml': 'application/xml',
    'apk': 'application/vnd.android.package-archive',
    'exe': 'application/x-msdownload'
  };
  let mime = map[ext];
  if (mime !== undefined) {
    return mime;
  }
  return 'application/octet-stream';
}

export function getMimeForFileName(fileName: string): string {
  let dot = fileName.lastIndexOf('.');
  if (dot < 0) {
    return 'application/octet-stream';
  }
  let ext = fileName.substring(dot + 1).toLowerCase();
  return getMimeForExt(ext);
}

// MIME 大类（`/` 前段）；无 `/` 时按整串处理，避免切成空串
function mimeCategory(mime: string): string {
  let slash = mime.indexOf('/');
  return slash > 0 ? mime.substring(0, slash) : mime;
}

/**
 * MTA sendRequest 顶层 MIME 的「三档口径」（与参考实现一致）：
 * 单文件取该文件真实 MIME；多文件且同大类取「大类 + 斜杠 + 星号」的大类通配；
 * 跨大类取全通配（星号 + 斜杠 + 星号）。对端以该字段判定预览能力，
 * 全通配与非媒体值都不会触发缩略图索取。
 */
export function aggregateMtaMimeType(mimes: Array<string>): string {
  if (mimes.length === 0) {
    return 'application/octet-stream';
  }
  if (mimes.length === 1) {
    return mimes[0];
  }
  let category = mimeCategory(mimes[0]);
  for (let i = 1; i < mimes.length; i++) {
    if (mimeCategory(mimes[i]) !== category) {
      return '*/*';
    }
  }
  return category + '/*';
}

const IMAGE_EXTENSIONS: Array<string> = ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'svg'];

export function isImageExtension(ext: string): boolean {
  return IMAGE_EXTENSIONS.indexOf(ext.toLowerCase()) >= 0;
}

// ── 文本类文件判定（唯一来源） ──

// 可按文本预览的扩展名（与 getMimeForExt 中的 text/* 映射保持一致）
const TEXT_EXTENSIONS: Array<string> = ['txt', 'text', 'log', 'md', 'markdown', 'json', 'xml',
  'html', 'htm', 'css', 'csv', 'tsv', 'yaml', 'yml', 'ini', 'conf', 'opml'];

/**
 * 是否为「文本类文件」（可读取内容按文本预览的唯一判定）：
 * 依据 MIME（text/* 或 JSON/XML 等文本型 MIME）与扩展名统一判定；
 * 各处不得自行比对 MIME 字符串，一律经此入口。
 */
function isTextMime(mime: string): boolean {
  if (mime.length === 0) {
    return false;
  }
  if (mime.startsWith('text/')) {
    return true;
  }
  return mime === 'application/json' || mime === 'application/xml' || mime === 'application/javascript';
}

/** 依据文件名（扩展名）判定是否为文本类文件。 */
function isTextFileName(fileName: string): boolean {
  let dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot >= fileName.length - 1) {
    return false;
  }
  let ext = fileName.substring(dot + 1).toLowerCase();
  return TEXT_EXTENSIONS.indexOf(ext) >= 0;
}

/** 文本类文件统一判定：MIME 或文件名任一命中即为文本类。 */
export function isTextFile(mime: string, fileName: string): boolean {
  return isTextMime(mime) || isTextFileName(fileName);
}
