import { common } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileUri } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import dataSharePredicates from '@ohos.data.dataSharePredicates';
import fs from '@ohos.file.fs';
import { LogCapture as Lg } from './LogCapture';

/**
 * 鸿蒙「动态照片」在发送侧的取数：图片 + 视频两个资源。
 *
 * 背景（这一步为什么必须有）：
 *   鸿蒙动态照片在图库里是「一个资产、两个资源」（静态图 + 短视频）。用系统文件选择器
 *   （DocumentViewPicker）选它时，交到应用手上的只是**静态图那一个文件** —— 实测一个
 *   相机动态照片被交付成 2MB 的 JPEG（HDR gain map 的 JPEG），里面没有任何视频段，
 *   XMP 里也没有 MotionPhoto 声明。因此「把动态照片拆成图片 + 视频发送」不可能只靠读文件
 *   完成，必须回到图库问系统要视频资源。
 *
 * 权限说明：`MediaAssetManager.requestMovingPhoto` / `MovingPhoto.requestContent` 在文档里
 * 标注需要 `ohos.permission.READ_IMAGEVIDEO`（system_basic）。本模块按「选择器授权」的
 * 路径实现：资产 URI 来自用户自己的选择动作，系统会给该资产临时授权。若系统仍以 201
 * （Permission denied）拒绝，本模块只记日志、返回 undefined，发送流程照旧（不会中断发送）。
 */
export interface MovingPhotoSegments {
  readonly imagePath: string;
  readonly videoPath: string;
  readonly imageSize: number;
  readonly videoSize: number;
}

/** 该 URI 是否指向图库资产（只有图库 URI 才可能对应动态照片）。 */
function isMediaUri(uri: string): boolean {
  return uri.startsWith('file://media/');
}

export class HarmonyMovingPhoto {
  /**
   * 若 `uri` 对应的图库资产是动态照片，则把它的图片段与视频段导出到 `dir`，返回两个路径。
   * 不是图库 URI / 不是动态照片 / 取数失败时返回 undefined（调用方按普通文件处理）。
   */
  static async extract(
    context: common.Context,
    uri: string,
    name: string,
    dir: string
  ): Promise<MovingPhotoSegments | undefined> {
    if (!isMediaUri(uri)) {
      return undefined;
    }
    try {
      const asset = await HarmonyMovingPhoto.findAsset(context, uri);
      if (asset === undefined) {
        Lg.i('[DYNAMIC] media asset not found for ' + name + ' (uri=' + uri + ')');
        return undefined;
      }
      const rawSubtype = asset.get(photoAccessHelper.PhotoKeys.PHOTO_SUBTYPE);
      const subtype = typeof rawSubtype === 'number' ? rawSubtype : Number.parseInt(String(rawSubtype), 10);
      Lg.i('[DYNAMIC] media asset subtype=' + subtype + ' (3=moving photo) name=' + name);
      if (subtype !== photoAccessHelper.PhotoSubtype.MOVING_PHOTO) {
        return undefined;
      }
      const stamp = Date.now().toString(36);
      const imagePath = dir + '/' + stamp + '-moving.jpg';
      const videoPath = dir + '/' + stamp + '-moving.mp4';
      const ok = await HarmonyMovingPhoto.requestContent(context, asset, imagePath, videoPath, name);
      if (!ok) {
        return undefined;
      }
      const imageSize = fs.statSync(imagePath).size;
      const videoSize = fs.statSync(videoPath).size;
      if (imageSize <= 0 || videoSize <= 0) {
        Lg.w('[DYNAMIC] moving photo resources empty image=' + imageSize + ' video=' + videoSize + ' name=' + name);
        return undefined;
      }
      Lg.i('[DYNAMIC] moving photo extracted: ' + name + ' image=' + imageSize + ' video=' + videoSize);
      return { imagePath: imagePath, videoPath: videoPath, imageSize: imageSize, videoSize: videoSize };
    } catch (error) {
      const business = error as BusinessError;
      const code = business !== undefined && business.code !== undefined ? business.code : -1;
      Lg.w('[DYNAMIC] moving photo extract failed for ' + name + ' code=' + code + ' '
        + (error instanceof Error ? error.message : JSON.stringify(error)));
      return undefined;
    }
  }

  /** 用 URI 精确查图库资产（选择器的 URI 就是资产的 uri 字段）。 */
  private static async findAsset(
    context: common.Context,
    uri: string
  ): Promise<photoAccessHelper.PhotoAsset | undefined> {
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    const predicates = new dataSharePredicates.DataSharePredicates();
    predicates.equalTo(photoAccessHelper.PhotoKeys.URI, uri);
    const options: photoAccessHelper.FetchOptions = {
      fetchColumns: [
        photoAccessHelper.PhotoKeys.URI,
        photoAccessHelper.PhotoKeys.PHOTO_SUBTYPE,
        photoAccessHelper.PhotoKeys.DISPLAY_NAME
      ],
      predicates: predicates
    };
    const result = await helper.getAssets(options);
    try {
      if (result.getCount() === 0) {
        return undefined;
      }
      return await result.getFirstObject();
    } finally {
      result.close();
    }
  }

  /**
   * 向系统要动态照片对象，并把图片/视频两个资源写到沙箱文件里。
   * `requestMovingPhoto` 是「回调式」接口（结果在 onDataPrepared 里），这里包成 Promise。
   */
  private static async requestContent(
    context: common.Context,
    asset: photoAccessHelper.PhotoAsset,
    imagePath: string,
    videoPath: string,
    name: string
  ): Promise<boolean> {
    const target: string[] = [imagePath, videoPath];
    return await new Promise<boolean>((resolve: (value: boolean) => void): void => {
      const handler: photoAccessHelper.MediaAssetDataHandler<photoAccessHelper.MovingPhoto> = {
        onDataPrepared: (data: photoAccessHelper.MovingPhoto): void => {
          if (data === undefined) {
            Lg.w('[DYNAMIC] moving photo data not ready for ' + name);
            resolve(false);
            return;
          }
          data.requestContent(fileUri.getUriFromPath(target[0]), fileUri.getUriFromPath(target[1]))
            .then((): void => resolve(true))
            .catch((error: BusinessError): void => {
              Lg.w('[DYNAMIC] requestContent failed for ' + name + ' code=' + error.code + ' ' + error.message);
              resolve(false);
            });
        }
      };
      const options: photoAccessHelper.RequestOptions = {
        deliveryMode: photoAccessHelper.DeliveryMode.FAST_MODE
      };
      photoAccessHelper.MediaAssetManager.requestMovingPhoto(context, asset, options, handler)
        .then((): void => undefined)
        .catch((error: BusinessError): void => {
          Lg.w('[DYNAMIC] requestMovingPhoto failed for ' + name + ' code=' + error.code + ' ' + error.message);
          resolve(false);
        });
    });
  }
}
