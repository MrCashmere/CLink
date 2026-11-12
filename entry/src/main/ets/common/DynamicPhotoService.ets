import { common } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import promptAction from '@ohos.promptAction';
import { toastSystemMaterial } from '../utils/SystemMaterial';
import { LogCapture as Lg } from './LogCapture';
import { SettingsStore } from './SettingsStore';
import { OutgoingFile } from '../model/TransferModels';
import { DynamicPhotoBridge, DynamicPhotoSendResult, DynamicPhotoRestoreResult,
  DYNAMIC_PHOTO_PAIR_MARKER } from './DynamicPhotoBridge';
import { HarmonyMovingPhoto } from './HarmonyMovingPhoto';
import { DynamicPhotoFormat, DynamicPhotoProbe } from './DynamicPhotoFormat';
import { PendingDynamicPhoto, ReceivedCandidate } from './DynamicPhotoBridge';
import { PendingDynamicPhotoStore } from './DynamicPhotoStore';
import { LivePhotoWriter } from './LivePhotoWriter';
import { HdrPhotoService } from './HdrPhotoService';
import { LivePhotoFormat, PeerDecision, PeerLivePhotoFormat } from './PeerLivePhotoFormat';
import { DeviceEndpoint } from '../model/TransferModels';
import { ByteUtils, readFileRange } from './ByteUtils';
import fs from '@ohos.file.fs';

/** 重封装动态图片时允许整体读入内存的单文件上限（与 DynamicPhotoBridge 内部判断一致）。 */
const MAX_CONVERT_BYTES = 96 * 1024 * 1024;

/**
 * 「动态图片传输(Beta)」总协调器。
 *
 * 发送方向：按对端品牌把动态图片封装成对方相册认得的格式（Apple 实况照片 / Android 动态照片
 * 叠加该品牌私有字段），识别不出或对端是鸿蒙/电脑时退回「图片 + 视频」两个普通文件；
 * 接收方向：识别非鸿蒙格式的动态图片，解析后用系统 API 还原成鸿蒙动态照片。
 *
 * 两端的开关都取自 SettingsStore.dynamicPhotoEnabled（设置页「动态图片传输」）。
 */

/** 已收到但还没配成对的动态图片素材（图片或视频）。 */
interface WaitingPiece {
  readonly path: string;
  readonly name: string;
  readonly size: number;
  readonly isVideo: boolean;
  readonly sourcePath: string;
  readonly at: number;
}

const WAIT_TTL_MS = 5 * 60 * 1000;
const MAX_WAIT_ENTRIES = 16;

export class DynamicPhotoService {
  /** 等待配对的素材（Apple Live Photo / 独立 mp4 的厂商形态）。 */
  private static waiting: Map<string, WaitingPiece> = new Map();
  private static receiveQueues: Map<string, Promise<boolean>> = new Map();
  private static fileSequence: number = 0;
  /**
   * 已经处理成「相册动态照片」的接收源路径（已落库或已登记待保存）。
   *
   * 用途：设置「动态图片/HDR图片不保存至下载文件夹」打开时，这些文件不再往下载文件夹放副本
   * —— 相册里已经有移动照片了，下载目录再存一份原始文件属重复。
   */
  private static galleryHandled: Map<string, number> = new Map<string, number>();
  /**
   * 已为动态照片配对而保留或复制的素材。
   *
   * 普通视频也会短暂进入 waiting 以探测是否可配对，但不能因此被判定为“动态照片已占用”；
   * 只有真正进入配对缓存或已恢复/待保存的动态照片才拥有普通媒体管线的优先权。
   */
  private static pairingClaimed: Map<string, number> = new Map<string, number>();

  /** 设置页开关状态。 */
  static enabled(): boolean {
    return SettingsStore.current().dynamicPhotoEnabled === true;
  }

  /** 占用只属于本次处理的源路径，不能用跨会话重名的 basename。 */
  static markHandledForGallery(sourcePath: string): void {
    if (sourcePath.length === 0) {
      return;
    }
    const key: string = DynamicPhotoService.localPath(sourcePath);
    DynamicPhotoService.pruneClaims();
    DynamicPhotoService.galleryHandled.set(key, Date.now());
    DynamicPhotoService.pairingClaimed.delete(key);
  }

  /**
   * 这个接收文件是否还需要往「下载」文件夹放副本。
   *
   * 规则：设置打开 + 该文件已被处理成相册动态照片 → 不再放副本（返回 false）。
   * 普通图片、以及功能关着的情况一律照旧放副本。
   */
  static shouldKeepDownloadCopy(sourcePath: string): boolean {
    if (!DynamicPhotoService.enabled() || SettingsStore.current().skipDownloadCopyForGalleryPhotos !== true) {
      return true;
    }
    DynamicPhotoService.pruneClaims();
    const hit = DynamicPhotoService.galleryHandled.has(DynamicPhotoService.localPath(sourcePath));
    if (hit) {
      Lg.i('[DYNAMIC] skip download copy (already in gallery): ' + sourcePath);
    }
    return !hit;
  }

  /**
   * 本文件是否已经由动态照片链路持有。
   *
   * 只认“已进入图库/待保存”与“确实为配对保留的素材”；普通图片和视频短暂进入
   * waiting 表不构成占用，否则会使普通视频永远绕过图库自动保存。
   */
  static isClaimedByDynamicPhoto(sourcePath: string): boolean {
    if (!DynamicPhotoService.enabled()) { return false; }
    DynamicPhotoService.pruneClaims();
    const key: string = DynamicPhotoService.localPath(sourcePath);
    return DynamicPhotoService.pairingClaimed.has(key) || DynamicPhotoService.galleryHandled.has(key);
  }

  static wasHandledForGallery(sourcePath: string): boolean {
    DynamicPhotoService.pruneClaims();
    return DynamicPhotoService.galleryHandled.has(DynamicPhotoService.localPath(sourcePath));
  }

  private static pruneClaims(): void {
    const now: number = Date.now();
    for (const claims of [DynamicPhotoService.galleryHandled, DynamicPhotoService.pairingClaimed]) {
      for (const key of Array.from(claims.keys())) {
        if (now - (claims.get(key) ?? 0) > WAIT_TTL_MS || claims.size > 128) { claims.delete(key); }
      }
    }
  }

  // ---------------------------------------------------------------------
  // 发送方向
  // ---------------------------------------------------------------------

  /**
   * 按对端设备与设置决定本次发送的封装格式。
   *
   * 所有发送入口（TransferManager 与各协议页面）共用这一套判定，避免「设置页改了格式、
   * 从 Quick Share 页发送却不生效」这类不一致。
   */
  static resolveFormatFor(device: DeviceEndpoint): PeerDecision {
    const fallback = PeerLivePhotoFormat.parseFallback(
      SettingsStore.current().defaultLivePhotoFormat ?? 'android');
    const decision = PeerLivePhotoFormat.resolve(PeerLivePhotoFormat.identityOf(device), fallback);
    Lg.i('[DYNAMIC] peer format: platform=' + decision.platform + ' brand='
      + (decision.brand.length > 0 ? decision.brand : '-') + ' target=' + decision.format
      + (decision.format === 'android' ? ' dialect=' + decision.dialect : '')
      + ' fallback=' + fallback + ' reason=' + decision.reason + ' peer=' + device.name
      // 把对端广播的 model 也打出来：识别失败时要能一眼看出「它到底有没有提供品牌线索」。
      + ' model=' + (device.model !== undefined && device.model.length > 0 ? device.model : '-'));
    return decision;
  }

  /**
   * 发送前处理：把列表中的动态图片按**对端支持的格式**封装。
   *
   * - `format === 'split'`（对端是鸿蒙/华为/荣耀、电脑，或功能选择不转换）：
   *   还是「图片 + 视频」两个文件 —— 接收端已验证可直接还原成鸿蒙动态照片；
   * - `format === 'apple'`：同名的 JPEG + MOV，两侧写入同一个资产标识（iOS「照片」据此配对）；
   * - `format === 'android'`：单个 JPEG，尾部追加 MP4，XMP 里同时写 Google 两套方言
   *   （新版 Container + 旧版 MicroVideoOffset），并按 `dialect` 叠加该品牌的私有命名空间
   *   （小米 / OPPO 系 / vivo 系 / 三星）。
   *
   * 任何一步失败都会**退回拆分结果**：拆分是唯一真机验证过的路径，宁可多两个文件，
   * 也不能因为封装失败而发不出去。
   */
  static async prepareOutgoing(
    context: common.Context,
    files: OutgoingFile[],
    decision: PeerDecision
  ): Promise<OutgoingFile[]> {
    const dynamic = DynamicPhotoService.enabled();
    // 「HDR照片转换为HDR Vivid格式」是独立开关，与动态图片无关：只开 HDR 时也要走这里。
    const hdr = HdrPhotoService.enabled();
    if ((!dynamic && !hdr) || files.length === 0) {
      Lg.i('[DYNAMIC] prepareOutgoing skipped (dynamic=' + dynamic + ' hdr=' + hdr
        + ' files=' + files.length + ')');
      return files;
    }
    // 对端不认 HDR（电脑/未知）时只发基础 SDR 层，避免把增益图白传一趟。
    // `desktop` = 网页传输时由 UA 判出的桌面浏览器（Linux/macOS 之外的桌面系统），与 Windows 同等对待。
    const hdrAware: boolean = decision.platform !== 'windows' && decision.platform !== 'desktop';
    // 对端是华为/鸿蒙时用「华为形态」（APP2 ISO URN + MPF attribute 0x50000），否则用 XMP 那套。
    const harmonyPeer: boolean = decision.platform === 'harmony';
    const format: LivePhotoFormat = decision.format;
    Lg.i('[DYNAMIC] prepareOutgoing: scanning ' + files.length + ' file(s), target='
      + PeerLivePhotoFormat.formatLabel(format)
      + (format === 'android' ? ' dialect=' + PeerLivePhotoFormat.dialectLabel(decision.dialect) : '')
      + ' hdr=' + hdr + ' hdrAware=' + hdrAware);
    const expanded: OutgoingFile[] = [];
    let split = 0;
    let converted = 0;
    let hdrRewritten = 0;
    for (const file of files) {
      try {
        const pair = dynamic ? await DynamicPhotoService.splitOutgoingFile(context, file) : undefined;
        if (pair === undefined) {
          // 普通照片（或动态图片功能关着）：按需做 HDR 增益图改写。
          const hdrResult = await HdrPhotoService.rewriteForSend(context, file.path, file.name, file.size,
            hdrAware, harmonyPeer);
          if (hdrResult !== undefined && hdrResult.files.length > 0) {
            // 显式映射成 OutgoingFile：两个接口字段相同，但不依赖结构化赋值，保持 ArkTS 严格模式友好。
            for (const item of hdrResult.files) {
              expanded.push({ path: item.path, name: item.name, size: item.size, mime: item.mime });
            }
            hdrRewritten += 1;
            continue;
          }
          expanded.push(file);
          continue;
        }
        if (format !== 'split') {
          const rewritten = await DynamicPhotoService.convertOutgoingPair(context, file, pair, decision);
          if (rewritten !== undefined) {
            for (const item of rewritten) {
              expanded.push(item);
            }
            converted += 1;
            continue;
          }
          Lg.w('[DYNAMIC] convert failed, fall back to split: ' + file.name);
        }
        // 拆开发送时图片是独立 JPEG：可以对它做 HDR 改写。
        // （封装成单个动态照片文件时不做：那会在同一个 XMP 里出现两套容器目录声明，
        //   见 docs/HDR_IMAGE.md §3；此时按 SDR 基础图发送，画面正常。）
        const image = pair[0];
        const hdrImage = await HdrPhotoService.rewriteForSend(context, image.path, image.name, image.size,
          hdrAware, harmonyPeer);
        if (hdrImage !== undefined && hdrImage.files.length > 0) {
          const rewrittenImage = hdrImage.files[0];
          pair[0] = {
            path: rewrittenImage.path, name: rewrittenImage.name,
            size: rewrittenImage.size, mime: rewrittenImage.mime
          };
          hdrRewritten += 1;
        }
        for (const item of pair) {
          expanded.push(item);
        }
        split += 1;
      } catch (error) {
        Lg.w('[DYNAMIC] prepareOutgoing failed for ' + file.name + ': '
          + (error instanceof Error ? error.message : JSON.stringify(error)));
        expanded.push(file);
      }
    }
    if (split === 0 && converted === 0 && hdrRewritten === 0) {
      Lg.flushNow();
      return files;
    }
    Lg.i('[DYNAMIC] prepareOutgoing: ' + files.length + ' -> ' + expanded.length + ' files, converted='
      + converted + ' split=' + split + ' hdr=' + hdrRewritten);
    Lg.flushNow();
    return expanded;
  }

  /**
   * 把一个文件拆成「图片 + 视频」两个沙箱文件；不是动态图片时返回 undefined。
   *
   * 两条来源：图库动态照片（HarmonyMovingPhoto 取回真实视频）与内嵌式动态图片（解析后按段切分）。
   */
  private static async splitOutgoingFile(
    context: common.Context,
    file: OutgoingFile
  ): Promise<OutgoingFile[] | undefined> {
    // 0) 图库动态照片：交到应用手上的文件只是静态图，视频要从图库单取（见 HarmonyMovingPhoto）。
    const moving = await HarmonyMovingPhoto.extract(context, file.path, file.name,
      DynamicPhotoBridge.workDir(context));
    if (moving !== undefined) {
      const base = DynamicPhotoFormat.stripPairMarker(DynamicPhotoFormat.baseNameOf(file.name));
      const stem = base.length > 0 ? base : 'movingphoto';
      const prefix = Date.now().toString(36) + '-';
      const imageName = stem + DYNAMIC_PHOTO_PAIR_MARKER + '.jpg';
      const videoName = stem + DYNAMIC_PHOTO_PAIR_MARKER + '.mp4';
      Lg.i('[DYNAMIC] send split (harmony moving photo): ' + file.name + ' -> ' + imageName + ' + ' + videoName);
      return [
        { path: moving.imagePath, name: prefix + imageName, size: moving.imageSize, mime: 'image/jpeg' },
        { path: moving.videoPath, name: prefix + videoName, size: moving.videoSize, mime: 'video/mp4' }
      ];
    }
    const result = await DynamicPhotoBridge.splitForSend(context, file.path, file.name, file.size);
    if (!result.split) {
      Lg.i('[DYNAMIC] send: not split ' + file.name + ' (kind=' + result.probe.kind
        + ' imageFormat=' + result.probe.imageFormat + ')');
      return undefined;
    }
    Lg.i('[DYNAMIC] send split: ' + file.name + ' -> ' + result.imageName + ' + ' + result.videoName
      + ' (' + result.probe.kind + '/' + result.probe.vendor + ')');
    return [
      {
        path: result.imagePath, name: result.imageName, size: result.imageSize,
        mime: DynamicPhotoService.mimeForExtension(result.imageName)
      },
      { path: result.videoPath, name: result.videoName, size: result.videoSize, mime: 'video/mp4' }
    ];
  }

  /**
   * 把「图片 + 视频」重封装成对端格式；失败返回 undefined（调用方退回拆分结果）。
   *
   * 只支持 JPEG 主图：Apple 与 Android 两套规范的静态图都是 JPEG，HEIC 要另写一套封装，
   * 这里不做（退回拆分，接收端仍能正确还原）。
   */
  private static async convertOutgoingPair(
    context: common.Context,
    source: OutgoingFile,
    pair: OutgoingFile[],
    decision: PeerDecision
  ): Promise<OutgoingFile[] | undefined> {
    if (pair.length < 2) {
      return undefined;
    }
    const imageFile = pair[0];
    const videoFile = pair[1];
    const imageExtension = DynamicPhotoFormat.extensionOf(imageFile.name);
    if (imageExtension !== 'jpg' && imageExtension !== 'jpeg') {
      Lg.i('[DYNAMIC] convert skipped (image is ' + imageExtension + ', not jpeg): ' + source.name);
      return undefined;
    }
    const image = await DynamicPhotoBridge.readWholeFile(imageFile.path, MAX_CONVERT_BYTES);
    const video = await DynamicPhotoBridge.readWholeFile(videoFile.path, MAX_CONVERT_BYTES);
    if (image === undefined || video === undefined) {
      return undefined;
    }
    const base = DynamicPhotoFormat.stripPairMarker(DynamicPhotoFormat.baseNameOf(source.name));
    const stem = base.length > 0 ? base : 'livephoto';
    const dir = DynamicPhotoBridge.workDir(context);
    const stamp = Date.now().toString(36);
    if (decision.format === 'android') {
      // HDR 动态照片：先试「HDR 感知封装」——图片段带增益图时，必须把增益图写进同一个
      // XMP 的容器目录（Primary + GainMap + MotionPhoto）并带上 hdrgm 与厂商字段，
      // 否则对端只会看到 SDR（真机实测：普通封装下 `hdr=0`、OPPO 不显示 HDR）。
      // 开关关闭或没有增益图时返回 undefined，退回原来的普通封装。
      if (HdrPhotoService.enabled()) {
        // 属性串必须用 `buildMotionPhotoAttributes()`（含 `GCamera:MotionPhoto="1"` 等动图声明），
        // 不能用只含厂商字段的 `buildMotionPhotoVendorAttributes()`：后者会让 HDR 动态照片的
        // XMP 缺少「这是动图」的声明，Google 相册不识别（真机实测）。
        const hdrFile = await HdrPhotoService.composeHdrMotionPhoto(context, imageFile.path, imageFile.name,
          imageFile.size, video,
          LivePhotoWriter.buildMotionPhotoAttributes(video.length, decision.dialect));
        if (hdrFile !== undefined) {
          Lg.i('[DYNAMIC] convert -> HDR 动态照片(' + PeerLivePhotoFormat.dialectLabel(decision.dialect)
            + '): ' + source.name + ' => ' + hdrFile.name);
          return [{ path: hdrFile.path, name: hdrFile.name, size: hdrFile.size, mime: hdrFile.mime }];
        }
      }
      const written = LivePhotoWriter.writeAndroidMotionPhoto(image, video, decision.dialect);
      if (written === undefined) {
        return undefined;
      }
      const name = stem + '.jpg';
      const path = dir + '/' + stamp + '-mp-' + name;
      if (DynamicPhotoBridge.writeWholeFile(path, written.bytes) <= 0) {
        return undefined;
      }
      Lg.i('[DYNAMIC] convert -> Android 动态照片(' + PeerLivePhotoFormat.dialectLabel(decision.dialect)
        + '): ' + source.name + ' => ' + name
        + ' (primary=' + written.primaryLength + ' video=' + written.videoLength + ')');
      return [{ path: path, name: name, size: written.bytes.length, mime: 'image/jpeg' }];
    }
    const identifier = LivePhotoWriter.newIdentifier();
    const live = LivePhotoWriter.writeAppleLivePhoto(image, video, identifier);
    if (live === undefined) {
      return undefined;
    }
    const imageName = stem + '.jpg';
    const videoName = stem + '.mov';
    const imagePath = dir + '/' + stamp + '-lp-' + imageName;
    const videoPath = dir + '/' + stamp + '-lp-' + videoName;
    if (DynamicPhotoBridge.writeWholeFile(imagePath, live.image) <= 0
      || DynamicPhotoBridge.writeWholeFile(videoPath, live.video) <= 0) {
      return undefined;
    }
    Lg.i('[DYNAMIC] convert -> Apple 实况照片: ' + source.name + ' => ' + imageName + ' + ' + videoName
      + ' (identifier=' + identifier + ')');
    return [
      { path: imagePath, name: imageName, size: live.image.length, mime: 'image/jpeg' },
      { path: videoPath, name: videoName, size: live.video.length, mime: 'video/quicktime' }
    ];
  }

  /** 只做识别不做拆分（UI 提示用：返回列表里有几个动态图片）。 */
  static async countDynamic(context: common.Context, files: OutgoingFile[]): Promise<number> {
    if (files.length === 0) {
      return 0;
    }
    let count = 0;
    for (const file of files) {
      const probe = await DynamicPhotoBridge.probePath(file.path, file.name, file.size);
      if (probe.kind !== 'none') {
        count += 1;
      }
    }
    return count;
  }

  /**
   * 传输结束后清理发送侧产生的拆分临时文件：
   * 只删除「不在原始选择列表里」且位于动态图片工作目录内的文件。
   */
  static cleanupOutgoing(original: OutgoingFile[], outgoing: OutgoingFile[]): void {
    if (outgoing.length === 0) {
      return;
    }
    const keep: Set<string> = new Set<string>();
    for (const file of original) {
      keep.add(file.path);
    }
    for (const file of outgoing) {
      if (keep.has(file.path)) {
        continue;
      }
      if (file.path.indexOf('/dynamicphoto/') < 0 && file.path.indexOf('/hdrphoto/') < 0) {
        continue;
      }
      try {
        fs.unlinkSync(file.path);
      } catch (error) {
        Lg.w('[DYNAMIC] cleanup temp failed: ' + file.path + ' '
          + (error instanceof Error ? error.message : JSON.stringify(error)));
      }
    }
  }

  // ---------------------------------------------------------------------
  // 接收方向
  // ---------------------------------------------------------------------

  /**
   * 一个文件落盘后的收尾处理：若它是非鸿蒙格式动态图片，则解析并还原为鸿蒙动态照片。
   * 返回本次是否发生了还原动作（调用方通常只用于日志）。
   */
  static async settleReceivedFile(
    context: common.Context,
    file: IncomingFileLike,
    batch: IncomingFileLike[],
    scope: string = ''
  ): Promise<boolean> {
    // 同一批可能并行上传。完成前一个文件的登记/还原，再处理下一个。
    const previous = DynamicPhotoService.receiveQueues.get(scope) ?? Promise.resolve(false);
    const current = previous.then(async (): Promise<boolean> => {
      const sourcePath = DynamicPhotoService.localPath(file.savedPath);
      if (DynamicPhotoService.wasHandledForGallery(sourcePath)
        && scope.length > 0 && DynamicPhotoService.enabled()) {
        return true;
      }
      DynamicPhotoService.galleryHandled.delete(sourcePath);
      DynamicPhotoService.pairingClaimed.delete(sourcePath);
      const handled = await DynamicPhotoService.settleReceivedFileInner(context, file, batch, scope);
      if (handled) {
        DynamicPhotoService.markHandledForGallery(sourcePath);
      } else if (!DynamicPhotoService.isClaimedByDynamicPhoto(sourcePath)) {
        await HdrPhotoService.convertReceivedInPlace(context, sourcePath, file.name);
      }
      return handled;
    }).catch((error: Error): boolean => {
      Lg.w('[DYNAMIC] settle failed: ' + error.message);
      return false;
    });
    DynamicPhotoService.receiveQueues.set(scope, current);
    try {
      return await current;
    } finally {
      if (DynamicPhotoService.receiveQueues.get(scope) === current) {
        DynamicPhotoService.receiveQueues.delete(scope);
      }
      Lg.flushNow();
    }
  }

  private static async settleReceivedFileInner(
    context: common.Context,
    file: IncomingFileLike,
    batch: IncomingFileLike[],
    scope: string
  ): Promise<boolean> {
    const extension = DynamicPhotoFormat.extensionOf(file.name);
    const isVideo = DynamicPhotoFormat.isVideoExtension(extension);
    const path = DynamicPhotoService.localPath(file.savedPath);
    if (!DynamicPhotoService.enabled() || (!isVideo && !DynamicPhotoFormat.isImageExtension(extension)
      && extension !== 'livp') || !DynamicPhotoService.exists(path)) {
      return false;
    }
    DynamicPhotoService.pruneWaiting();
    const token = await DynamicPhotoBridge.pairToken(path, file.name, file.size, isVideo);
    const key = scope + '\u0000' + token;
    const waiting = token.length > 0 ? DynamicPhotoService.waiting.get(key) : undefined;
    if (!isVideo) {
      const candidates = DynamicPhotoService.batchCandidates(batch, path);
      if (waiting?.isVideo === true) {
        const existing = candidates.findIndex((item: ReceivedCandidate): boolean => item.path === waiting.sourcePath);
        if (existing >= 0) { candidates.splice(existing, 1); }
        candidates.push({ name: waiting.name, path: waiting.path, size: waiting.size });
      }
      const received = await DynamicPhotoBridge.probeReceived(path, file.name, file.size, candidates);
      if (received.probe.kind === 'harmony-livp' || (received.probe.kind !== 'none' && received.probe.videoOffset >= 0)) {
        return await DynamicPhotoService.restoreEmbedded(context, path, file.name, file.size, received.probe);
      }
      if (received.videoPath.length > 0 && await DynamicPhotoService.finishRestore(
        context, path, received.videoPath, file.name, received.probe)) {
        if (waiting !== undefined && waiting.path === received.videoPath) {
          DynamicPhotoService.markHandledForGallery(waiting.sourcePath);
          DynamicPhotoService.removeWaiting(key);
        }
        return true;
      }
    } else if (waiting !== undefined && !waiting.isVideo) {
      const received = await DynamicPhotoBridge.probeReceived(waiting.path, waiting.name, waiting.size,
        [{ path: path, name: file.name, size: file.size }]);
      if (received.videoPath === path && await DynamicPhotoService.finishRestore(
        context, waiting.path, path, waiting.name, received.probe)) {
        DynamicPhotoService.markHandledForGallery(waiting.sourcePath);
        DynamicPhotoService.removeWaiting(key);
        return true;
      }
    }
    if (token.length > 0 && waiting === undefined && DynamicPhotoBridge.inSandbox(path)) {
      await DynamicPhotoService.stageForPairing(context, path, file.name, file.size, key, isVideo);
    }
    return false;
  }

  /** 留下已确认带配对标记的副本；源文件仍可以安全落到下载目录。 */
  private static async stageForPairing(context: common.Context, path: string, name: string,
    size: number, key: string, isVideo: boolean): Promise<void> {
    const dir = DynamicPhotoBridge.workDir(context);
    const target = dir + '/stage-' + DynamicPhotoService.uniquePrefix() + DynamicPhotoService.safeFileName(name);
    try {
      const copied = await DynamicPhotoBridge.copyFile(path, target, size);
      if (copied !== size || copied <= 0) {
        DynamicPhotoService.removeFile(target);
        return;
      }
      if (DynamicPhotoService.waiting.size >= MAX_WAIT_ENTRIES) {
        const keys = Array.from(DynamicPhotoService.waiting.keys());
        DynamicPhotoService.removeWaiting(keys[0]);
      }
      DynamicPhotoService.waiting.set(key, {
        path: target, sourcePath: path, name: name, size: copied, isVideo: isVideo, at: Date.now()
      });
      DynamicPhotoService.pruneClaims();
      DynamicPhotoService.pairingClaimed.set(path, Date.now());
    } catch (error) {
      DynamicPhotoService.removeFile(target);
      Lg.w('[DYNAMIC] stage for pairing failed: ' + String(error));
    }
  }

  private static exists(path: string): boolean {
    try {
      return path.length > 0 && fs.accessSync(path);
    } catch (error) {
      return false;
    }
  }

  private static safeFileName(name: string): string {
    const slash = name.lastIndexOf('/');
    const base = slash >= 0 ? name.substring(slash + 1) : name;
    return base.replace(/[\\/:*?"<>|]/g, '_');
  }

  private static uniquePrefix(): string {
    return Date.now().toString(36) + '-' + (++DynamicPhotoService.fileSequence).toString(36) + '-';
  }

  /** 各协议在一批结束时释放配对副本；其他会话的等待项不受影响。 */
  static async settleBatch(_context: common.Context, _batch: IncomingFileLike[], scope: string = ''): Promise<void> {
    await DynamicPhotoService.receiveQueues.get(scope);
    const prefix = scope + '\u0000';
    for (const key of Array.from(DynamicPhotoService.waiting.keys())) {
      if (key.startsWith(prefix)) { DynamicPhotoService.removeWaiting(key); }
    }
  }

  /**
   * 图片尾部内嵌视频：把图片段与视频段都拆到应用沙箱缓存，然后走统一还原流程。
   *
   * 为什么复用发送侧的 splitForSend：
   *  - 接收到的文件可能被协议直接落在 Download（沙箱外），而 photoAccessHelper.addResource
   *    只接受沙箱 URI —— 拆分顺带把两段都复制进缓存目录，天然满足沙箱要求；
   *  - 图片段同时被裁掉尾部视频段，得到一张干净的静态图片（鸿蒙动态照片的图片资源）。
   */
  private static async restoreEmbedded(
    context: common.Context,
    imagePath: string,
    imageName: string,
    imageSize: number,
    probe: DynamicPhotoProbe
  ): Promise<boolean> {
    const split = await DynamicPhotoBridge.splitForSend(context, imagePath, imageName, imageSize);
    if (!split.split || split.videoPath.length === 0) {
      Lg.w('[DYNAMIC] embedded split failed for ' + imageName + ' split=' + split.split);
      return false;
    }
    Lg.i('[DYNAMIC] embedded segments materialized: ' + split.imagePath + ' + ' + split.videoPath
      + ' (' + probe.kind + '/' + probe.vendor + ')');
    // HDR 在统一落库入口处理，内嵌式和图片/视频配对式执行相同规则。
    return await DynamicPhotoService.finishRestore(context, split.imagePath, split.videoPath,
      imageName, probe);
  }

  /**
   * 把「图片 + 视频」复制到持久目录，返回 [图片路径, 视频路径]。
   * 已经是持久目录下的则原样返回；复制失败时返回空列表，避免登记不可用的素材。
   */
  private static async makeDurable(
    context: common.Context,
    imagePath: string,
    videoPath: string,
    imageName: string
  ): Promise<string[]> {
    try {
      const dir = DynamicPhotoBridge.pendingDir(context);
      if (imagePath.startsWith(dir) && videoPath.startsWith(dir)) {
        return [imagePath, videoPath];
      }
      const stem = DynamicPhotoService.safeFileName(
        DynamicPhotoFormat.stripPairMarker(DynamicPhotoFormat.baseNameOf(imageName)));
      const prefix = DynamicPhotoService.uniquePrefix();
      const imageExtension = DynamicPhotoFormat.extensionOf(imagePath) || 'jpg';
      const videoExtension = DynamicPhotoFormat.extensionOf(videoPath) || 'mp4';
      const imageTarget = dir + '/' + prefix + (stem.length > 0 ? stem : 'movingphoto') + '.' + imageExtension;
      const videoTarget = dir + '/' + prefix + (stem.length > 0 ? stem : 'movingphoto') + '.' + videoExtension;
      const imageCopied = await DynamicPhotoBridge.copyFile(imagePath, imageTarget, DynamicPhotoService.sizeOf(imagePath));
      const videoCopied = await DynamicPhotoBridge.copyFile(videoPath, videoTarget, DynamicPhotoService.sizeOf(videoPath));
      if (imageCopied <= 0 || imageCopied !== DynamicPhotoService.sizeOf(imagePath)
        || videoCopied <= 0 || videoCopied !== DynamicPhotoService.sizeOf(videoPath)) {
        DynamicPhotoService.removeFile(imageTarget);
        DynamicPhotoService.removeFile(videoTarget);
        return [];
      }
      return [imageTarget, videoTarget];
    } catch (error) {
      Lg.w('[DYNAMIC] makeDurable failed: ' + (error instanceof Error ? error.message : JSON.stringify(error)));
      return [];
    }
  }

  private static sizeOf(path: string): number {
    try {
      return fs.statSync(path).size;
    } catch (error) {
      return 0;
    }
  }

  /**
   * 直接落库成功后的用户反馈。
   *
   * 为什么要延迟：落库紧接着会发生「保存到下载目录」的系统文件选择器（模态窗口），
   * 立刻弹 Toast 会被它吞掉（日志里表现为 Toast 挂不上根节点）。用户看不到任何提示时
   * 会以为「又是普通图片」，所以这里等选择器收起后再提示。
   */
  private static notifySaved(): void {
    setTimeout((): void => {
      try {
        promptAction.showToast({
          systemMaterial: toastSystemMaterial(),
          message: '动态照片已保存到图库'
        });
      } catch (error) {
        Lg.w('[DYNAMIC] saved toast failed: ' + JSON.stringify(error));
      }
    }, 1200);
  }

  /** 统一落库：调用系统 API 创建鸿蒙动态照片；权限不足则登记待保存。 */
  private static async finishRestore(
    context: common.Context,
    imagePath: string,
    videoPath: string,
    imageName: string,
    probe: DynamicPhotoProbe
  ): Promise<boolean> {
    if (!DynamicPhotoBridge.inSandbox(imagePath) || !DynamicPhotoBridge.inSandbox(videoPath)) {
      Lg.w('[DYNAMIC] skip restore: not in sandbox image=' + imagePath + ' video=' + videoPath);
      return false;
    }
    const title = DynamicPhotoFormat.stripPairMarker(DynamicPhotoFormat.baseNameOf(imageName));
    const converted: string | undefined = await HdrPhotoService.prepareForLocal(
      context, imagePath, imageName, DynamicPhotoService.sizeOf(imagePath));
    const imageForSave: string = converted ?? imagePath;
    const result: DynamicPhotoRestoreResult = await DynamicPhotoBridge.restore(context, imageForSave, videoPath, title);
    if (result.restored) {
      Lg.i('[DYNAMIC] restored harmony moving photo: ' + result.assetUri + ' from ' + probe.kind + '/' + probe.vendor);
      // 已经进相册了：登记一下，供「不保存至下载文件夹」判定（见 shouldKeepDownloadCopy）。
      DynamicPhotoService.markHandledForGallery(imagePath);
      DynamicPhotoService.markHandledForGallery(videoPath);
      DynamicPhotoService.notifySaved();
      return true;
    }
    if (result.pendingSave) {
      // 待用户点 SaveButton 的素材要落到持久目录（cacheDir 会被系统在后台清理）。
      const durable = await DynamicPhotoService.makeDurable(context, imageForSave, videoPath, imageName);
      if (durable.length !== 2) { return false; }
      const photo: PendingDynamicPhoto = {
        title: title,
        imagePath: durable[0],
        videoPath: durable[1],
        vendor: probe.vendor.length > 0 ? probe.vendor : 'Generic',
        createdAt: Date.now()
      };
      const added = PendingDynamicPhotoStore.add(photo);
      Lg.i('[DYNAMIC] queued for SaveButton: ' + title + ' (' + result.error + ') added=' + added
        + ' image=' + durable[0] + ' video=' + durable[1]);
      if (added) {
        // 已登记待保存（素材落在 dynamicphoto-pending 持久目录、卡片在 App 里可见）：
        // 同样算「相册里将会有一份」，因此也登记进表里。
        DynamicPhotoService.markHandledForGallery(imagePath);
        DynamicPhotoService.markHandledForGallery(videoPath);
      }
      return added;
    }
    Lg.w('[DYNAMIC] restore failed: ' + result.error);
    DynamicPhotoService.pairingClaimed.delete(imagePath);
    DynamicPhotoService.pairingClaimed.delete(videoPath);
    return false;
  }

  // ---------------------------------------------------------------------
  // 配对等待表
  // ---------------------------------------------------------------------

  private static batchCandidates(batch: IncomingFileLike[], selfPath: string): ReceivedCandidate[] {
    const candidates: ReceivedCandidate[] = [];
    for (const item of batch) {
      const path = DynamicPhotoService.localPath(item.savedPath);
      if (path !== selfPath && DynamicPhotoService.exists(path)
        && !DynamicPhotoService.wasHandledForGallery(path)) {
        candidates.push({ name: item.name, path: path, size: item.size });
      }
    }
    return candidates;
  }

  private static removeFile(path: string): void {
    try { fs.unlinkSync(path); } catch (_error) {}
  }

  private static removeWaiting(key: string): void {
    const piece = DynamicPhotoService.waiting.get(key);
    if (piece !== undefined) {
      DynamicPhotoService.waiting.delete(key);
      DynamicPhotoService.pairingClaimed.delete(piece.sourcePath);
      DynamicPhotoService.removeFile(piece.path);
    }
  }

  private static pruneWaiting(): void {
    const now = Date.now();
    for (const key of Array.from(DynamicPhotoService.waiting.keys())) {
      const piece = DynamicPhotoService.waiting.get(key);
      if (piece !== undefined && now - piece.at > WAIT_TTL_MS) {
        DynamicPhotoService.removeWaiting(key);
      }
    }
  }

  // ---------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------

  /** file:// URI 或绝对路径统一转成本地绝对路径。 */
  static localPath(savedPath: string): string {
    if (savedPath === undefined || savedPath === null || savedPath.length === 0) {
      return '';
    }
    if (!savedPath.startsWith('file://')) {
      return savedPath;
    }
    try {
      return new fileUri.FileUri(savedPath).path;
    } catch (error) {
      const stripped = savedPath.substring('file://'.length);
      const slash = stripped.indexOf('/');
      return slash >= 0 ? stripped.substring(slash) : stripped;
    }
  }

  private static mimeForExtension(name: string): string {
    const extension = DynamicPhotoFormat.extensionOf(name);
    switch (extension) {
      case 'jpg':
      case 'jpeg':
      case 'jpe':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'heic':
      case 'heif':
      case 'hif':
        return 'image/heic';
      case 'webp':
        return 'image/webp';
      case 'avif':
        return 'image/avif';
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      default:
        return 'application/octet-stream';
    }
  }
}

/** 接收侧的最小文件描述（避免与 model 层循环依赖）。 */
export interface IncomingFileLike {
  readonly name: string;
  readonly size: number;
  readonly savedPath: string;
}
