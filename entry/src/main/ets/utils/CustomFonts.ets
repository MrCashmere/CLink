import { fileIo as fs } from '@kit.CoreFileKit';
import { text } from '@kit.ArkGraphics2D';

/**
 * 启动时加载所有已上传的自定义字体到全局字体集合，
 * 之后页面可通过字体别名（文件名去掉扩展名）引用。
 */
export function loadCustomFonts(filesDir: string, customFonts: string[]): void {
  try {
    const dir = `${filesDir}/custom_fonts`;
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir);
      return;
    }
    for (let i = 0; i < customFonts.length; i++) {
      const fileName = customFonts[i];
      const targetPath = `${dir}/${fileName}`;
      if (!fs.accessSync(targetPath)) {
        continue;
      }
      const alias = fileName.substring(0, fileName.length - 4);
      try {
        text.FontCollection.getGlobalInstance().loadFontSyncWithCheck(alias, `file://${targetPath}`);
      } catch (err) {
        // Skip fonts that can no longer be loaded.
      }
    }
  } catch (err) {
  }
}
