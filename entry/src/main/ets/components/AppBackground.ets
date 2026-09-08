/**
 * 全局自定义背景图。背景图通过 AppStorage['backgroundImage'] 提供，
 * 为空时不渲染（使用默认纯色背景）。
 */
@Component
export struct AppBackground {
  @StorageProp('backgroundImage') wallpaperImage: string = '';

  build() {
    if (this.wallpaperImage.length > 0) {
      Image(this.wallpaperImage)
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Cover)
        .expandSafeArea([SafeAreaType.SYSTEM],
          [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
    }
  }
}
