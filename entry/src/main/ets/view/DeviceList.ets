import { DeviceEndpoint, Protocols } from '../model/TransferModels';
import { HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwGlassBorder, reloadAppTheme, HwColor } from '../utils/DesignTokens';
import { cardGlassEffect, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';
import { CardSurface } from '../components/CardSurface';
import { AccentColorSentinel } from '../components/MaterialCard';

@Component
export struct DeviceList {
  /** 主题色变化时触发重建，让 HwColor.primary 与选中态取到新色值 */
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  /** 页面底色（由 applyAppTheme 发布）。直接读 HwColor.background 登记不上依赖 */
  @StorageProp('pageBackground') pageBackground: string = '';
  @Prop devices: DeviceEndpoint[] = [];
  onSelect: (device: DeviceEndpoint) => void = () => undefined;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('beautifulCards') beautifulCards: boolean = false;
  @StorageLink('classicCards') classicCards: boolean = false;
  @StorageLink('cardShadowBorder') cardShadowBorder: boolean = true;
  @StorageLink('experimentalCards') experimentalCards: boolean = false;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;

  private appFontFamily(content: string): string {
    if (this.fontMode !== 'custom') {
      return 'HarmonyOS Sans';
    }
    const family = this.hasCjk(content) ? this.fontFamilyZh : this.fontFamilyEn;
    return family === 'system' || family.length === 0 ? 'HarmonyOS Sans' : family;
  }

  private hasCjk(content: string): boolean {
    for (let i = 0; i < content.length; i++) {
      const code = content.charCodeAt(i);
      if (code >= 0x4E00 && code <= 0x9FFF) {
        return true;
      }
    }
    return false;
  }

  private appFontWeight(): number {
    return this.fontWeightMode === 'custom' ? this.fontWeightValue : 400;
  }

  /** 主题色变了：HwColor 是模块级对象，改属性不会触发刷新，靠这里重建页面 */
  onAccentColorChanged(): void {
    reloadAppTheme();
  }

  /** 当前主题色。读 accentColor 建立依赖；直接写 HwColor.primary 切色后不会重新求值 */
  private accentOrPrimary(): string {
    return this.accentColor.length > 0 ? this.accentColor : HwColor.primary;
  }

  build() {
    Column({ space: 12 }) {
      // 主题色依赖：切色时让本列表重新求值（零尺寸，不参与布局）
      AccentColorSentinel()
      ForEach(this.devices, (device: DeviceEndpoint) => {
        CardSurface({ radius: HwRadius.control }) {
          Column({ space: 6 }) {
            Row({ space: 8 }) {
              Text(device.name)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontFamily(this.appFontFamily(device.name))
                .fontColor(hwTextPrimary(this.isDarkMode))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(Protocols.info(device.protocol).label)
                .fontSize(11)
                .fontFamily(this.appFontFamily(Protocols.info(device.protocol).label))
                .fontWeight(this.appFontWeight())
                .fontColor('#04121F')
                .backgroundColor(Protocols.info(device.protocol).badgeColor)
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(8)
            }
            .width('100%')
            Text(this.describe(device))
              .fontSize(12)
              .fontFamily(this.appFontFamily(this.describe(device)))
              .fontWeight(this.appFontWeight())
              .fontColor(hwTextSecondary(this.isDarkMode))
              .width('100%')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .padding(HwSpace.lg)
          .borderRadius(HwRadius.control)
          .backgroundColor(Color.Transparent)
          .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
          .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
          .clip(true)
          .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
          .width('100%')
          .onClick(() => this.onSelect(device))
        }
      }, (device: DeviceEndpoint) => device.id + ':' + this.accentColor)
    }
    .width('100%')
  }

  private describe(device: DeviceEndpoint): string {
    const source = device.source === 'mdns' ? '局域网' : (device.source === 'ble' ? '蓝牙' : device.source);
    if (device.address.length === 0) {
      return `${source} 发现`;
    }
    return `${source} · ${device.address}${device.port > 0 ? `:${device.port}` : ''}`;
  }
}