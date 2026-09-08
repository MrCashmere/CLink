import { DeviceEndpoint, Protocols } from '../model/TransferModels';
import { HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwGlassSurface, hwGlassBorder } from '../utils/DesignTokens';
import {
  immersiveMaterialModifier,
  legacyMaterialModifier,
  isApi26OrAbove
} from '../utils/SystemMaterial';

@Component
export struct DeviceList {
  @Prop devices: DeviceEndpoint[] = [];
  onSelect: (device: DeviceEndpoint) => void = () => undefined;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
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

  build() {
    Column({ space: 12 }) {
      ForEach(this.devices, (device: DeviceEndpoint) => {
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
        .backgroundColor(hwGlassSurface(this.isDarkMode))
        .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
        .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
        .clip(true)
        .width('100%')
        .onClick(() => this.onSelect(device))
      }, (device: DeviceEndpoint) => device.id)
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