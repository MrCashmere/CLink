import { LogCapture as Lg } from '../common/LogCapture';
import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  HwColor,
  HwRadius,
  HwSpace,
  hwTextPrimary,
  hwTextSecondary,
  hwPrimary,
  hwDanger,
  hwSurface,
  hwGlassSurface,
  hwGlassBorder
} from '../utils/DesignTokens';
import {
  immersiveMaterialModifier,
  legacyMaterialModifier,
  isApi26OrAbove
} from '../utils/SystemMaterial';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { SettingsStore } from '../common/SettingsStore';
import { AppServices } from '../common/AppServices';

@Component
export struct SettingsPage {
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  @State alias: string = '羊绒互传';
  @State requirePin: boolean = true;
  @State alwaysVisible: boolean = true;
  @State quickshareWlanDirect: boolean = false;
  @State btMac: string = '';
  @State wifiUpgradeTcp: boolean = false;
  @State encryptionEnabled: boolean = true;
  @State receivePin: string = '';
  @State keepAlive: boolean = true;

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

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    SettingsStore.load(context).then((settings) => {
      this.alias = settings.alias;
      this.requirePin = settings.requirePin;
      this.alwaysVisible = settings.alwaysVisible;
      this.quickshareWlanDirect = settings.quickshareWlanDirect;
      this.btMac = settings.btMac;
      this.wifiUpgradeTcp = settings.wifiUpgradeTcp;
      this.encryptionEnabled = settings.encryptionEnabled !== false;
      this.receivePin = settings.receivePin ?? '';
      this.keepAlive = settings.keepAlive !== false;
    });
  }

  private persist(): void {
    const context = getContext(this) as common.UIAbilityContext;
    SettingsStore.save(context, {
      alias: this.alias.length > 0 ? this.alias : '羊绒互传',
      requirePin: this.requirePin,
      alwaysVisible: this.alwaysVisible,
      quickshareWlanDirect: this.quickshareWlanDirect,
      btMac: this.btMac.trim(),
      wifiUpgradeTcp: this.wifiUpgradeTcp,
      encryptionEnabled: this.encryptionEnabled,
      receivePin: this.receivePin.trim(),
      keepAlive: this.keepAlive
    });
  }

  @Builder
  backBar() {
    Row({ space: 12 }) {
      IconCircleButton({
        symbol: $r('sys.symbol.chevron_left'),
        buttonSize: 40,
        iconSize: 20,
        onAction: (): void => {
          this.persist();
          router.back();
        }
      })
      Text('设置')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontFamily(this.appFontFamily('设置'))
        .fontColor(hwTextPrimary(this.isDarkMode))
      Blank()
    }
    .width('100%')
    .height(56 + this.statusBarHeight)
    .padding({ left: 16, right: 16, top: this.statusBarHeight })
    .backgroundEffect({ radius: 12, color: this.isDarkMode ? '#6624282B' : '#66FFFFFF' })
  }

  @Builder
  aliasCard() {
    Column({ space: 8 }) {
      Text('设备名称')
        .fontSize(13)
        .fontColor(hwTextSecondary(this.isDarkMode))
        .fontFamily(this.appFontFamily('设备名称'))
        .fontWeight(this.appFontWeight())
        .width('100%')
      TextInput({ text: this.alias, placeholder: '设备名称' })
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor(hwTextPrimary(this.isDarkMode))
        .backgroundColor(hwSurface(this.isDarkMode))
        .borderRadius(HwRadius.control)
        .onChange((value: string) => {
          this.alias = value;
          this.persist();
        })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  pinRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('传输前要求PIN验证')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('传输前要求PIN验证'))
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('双方显示相同PIN，确认后传输，防止中间人攻击')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('双方显示相同PIN，确认后传输，防止中间人攻击'))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.requirePin })
        .selectedColor(hwPrimary(this.isDarkMode))
        .onChange((value: boolean) => {
          this.requirePin = value;
          this.persist();
        })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  visibleRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('本机可见')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('本机可见'))
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('持续广播 mDNS / BLE，让附近设备随时发现本机并发送文件')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('持续广播 mDNS / BLE，让附近设备随时发现本机并发送文件'))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.alwaysVisible })
        .selectedColor(hwPrimary(this.isDarkMode))
        .onChange((value: boolean) => {
          this.alwaysVisible = value;
          this.persist();
        })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  wlanDirectRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('Quick Share 蓝牙BLE传输优先')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('Quick Share 蓝牙BLE传输优先'))
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('开启后仅可通过蓝牙接收文件，无法发送文件，仅在默认模式失效时启用')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('开启后仅可通过蓝牙接收文件，无法发送文件，仅在默认模式失效时启用'))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.quickshareWlanDirect })
        .selectedColor(hwPrimary(this.isDarkMode))
        .onChange((value: boolean) => {
          this.quickshareWlanDirect = value;
          this.persist();
        })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  btMacCard() {
    Column({ space: 8 }) {
      Text('Windows Nearby 蓝牙 MAC 地址')
        .fontSize(13)
        .fontColor(hwTextSecondary(this.isDarkMode))
        .fontFamily(this.appFontFamily('Windows Nearby 蓝牙 MAC 地址'))
        .fontWeight(this.appFontWeight())
        .width('100%')
      TextInput({ text: this.btMac, placeholder: 'AA:BB:CC:DD:EE:FF' })
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor(hwTextPrimary(this.isDarkMode))
        .backgroundColor(hwSurface(this.isDarkMode))
        .borderRadius(HwRadius.control)
        .onChange((value: string) => {
          this.btMac = value;
          this.persist();
        })
      Text('用于接收 Windows 发送的文件。Windows 通过该地址用蓝牙连接手机；请在手机 设置→关于本机→状态信息 中找到“蓝牙地址”填入。')
        .fontSize(11)
        .fontColor(hwTextSecondary(this.isDarkMode))
        .fontFamily(this.appFontFamily('用于接收 Windows 发送的文件。Windows 通过该地址用蓝牙连接手机；请在手机 设置→关于本机→状态信息 中找到“蓝牙地址”填入。'))
        .fontWeight(this.appFontWeight())
        .width('100%')
        .lineHeight(15)
      if (this.btMac.trim().length === 0) {
        Text('未填写蓝牙 MAC 地址：Windows 只能“扫到”本机但无法连接发送文件。请填入手机真实蓝牙地址后再试。')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(hwDanger(this.isDarkMode))
          .fontFamily(this.appFontFamily('未填写蓝牙 MAC 地址：Windows 只能“扫到”本机但无法连接发送文件。请填入手机真实蓝牙地址后再试。'))
          .width('100%')
      }
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  wifiUpgradeRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('Windows Nearby 优先 Wi-Fi (TCP) 传输')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('开启后，Windows 通过蓝牙发现本机时会把会话自动升级到 Wi-Fi (TCP 5040) 传输大文件；关闭则全程走蓝牙。')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.wifiUpgradeTcp })
        .selectedColor(hwPrimary(this.isDarkMode))
        .onChange((value: boolean) => {
          this.wifiUpgradeTcp = value;
          this.persist();
        })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  receivePinCard() {
    Column({ space: 8 }) {
      Text('接收 PIN（可选）')
        .fontSize(13)
        .fontColor(hwTextSecondary(this.isDarkMode))
        .fontWeight(this.appFontWeight())
        .width('100%')
      TextInput({ text: this.receivePin, placeholder: '留空表示不要求 PIN' })
        .width('100%')
        .height(44)
        .fontSize(15)
        .fontColor(hwTextPrimary(this.isDarkMode))
        .backgroundColor(hwSurface(this.isDarkMode))
        .borderRadius(HwRadius.control)
        .onChange((value: string) => {
          this.receivePin = value;
          this.persist();
        })
      Text('对端发送方需输入此 PIN 才能向本机发文件（LocalSend 官方语义），连错 3 次锁定。')
        .fontSize(11)
        .fontColor(hwTextSecondary(this.isDarkMode))
        .fontWeight(this.appFontWeight())
        .width('100%')
        .lineHeight(15)
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  encryptionRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('LocalSend 加密传输 (TLS)')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('尝试用 HTTPS 接收；若对端不支持加密则回退明文（服务端 TLS 接线见后续阶段）')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.encryptionEnabled })
        .selectedColor(hwPrimary(this.isDarkMode))
        .onChange((value: boolean) => {
          this.encryptionEnabled = value;
          this.persist();
        })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  keepAliveRow() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('长时任务保活')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('开启后，进入后台也能持续运行以接收对端发送的文件，不再被系统短暂冻结')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.keepAlive })
        .selectedColor(hwPrimary(this.isDarkMode))
        .onChange((value: boolean) => {
          this.keepAlive = value;
          const context = getContext(this) as common.UIAbilityContext;
          if (value) {
            // 打开保活即在前台申请通知授权，保证连续任务的通知能显示。
            AppServices.get(context).ensureKeepAliveNotificationPermission().catch((): void => undefined);
          } else {
            AppServices.get(context).stopContinuousTask().catch((): void => undefined);
          }
          this.persist();
        })
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
  }

  @Builder
  appearanceRow() {
    Row({ space: 12 }) {
      IconCircleButton({ symbol: $r('sys.symbol.paintpalette'), buttonSize: 36, iconSize: 18 })
      Column({ space: 2 }) {
        Text('外观设置')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('外观设置'))
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('字体、字号、字重与背景图')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('字体、字号、字重与背景图'))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([hwTextSecondary(this.isDarkMode)])
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.control)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => {
      this.persist();
      router.pushUrl({ url: 'pages/AppearanceSettingsPage' }).catch((error: BusinessError): void => {
        Lg.w('Appearance route failed: ' + error.message);
      });
    })
  }

  @Builder
  aboutRow() {
    Row({ space: 12 }) {
      IconCircleButton({ symbol: $r('sys.symbol.info_circle'), buttonSize: 36, iconSize: 18 })
      Column({ space: 2 }) {
        Text('关于')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontFamily(this.appFontFamily('关于'))
          .fontColor(hwTextPrimary(this.isDarkMode))
        Text('版本信息、开源与版权说明')
          .fontSize(12)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('版本信息、开源与版权说明'))
          .fontWeight(this.appFontWeight())
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([hwTextSecondary(this.isDarkMode)])
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.control)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => {
      this.persist();
      router.pushUrl({ url: 'pages/AboutPage' }).catch((error: BusinessError): void => {
        Lg.w('About route failed: ' + error.message);
      });
    })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      AppBackground()
      Column() {
        Scroll() {
          Column({ space: 12 }) {
            Blank().height(56 + this.statusBarHeight)
            Column({ space: 12 }) {
              this.aliasCard()
              this.pinRow()
              this.visibleRow()
              this.wlanDirectRow()
              this.btMacCard()
              this.wifiUpgradeRow()
              this.receivePinCard()
              this.encryptionRow()
              this.keepAliveRow()
              this.appearanceRow()
              this.aboutRow()
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 32 })
          }
          .width('100%')
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')

      this.backBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDarkMode ? HwColor.backgroundDark : HwColor.background)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
