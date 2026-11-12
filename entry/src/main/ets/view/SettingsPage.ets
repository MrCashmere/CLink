import { LogCapture as Lg } from '../common/LogCapture';
import router from '@ohos.router';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { HwColor, HwRadius, HwSpace, hwTextPrimary, hwTextSecondary, hwPrimary, hwPrimaryButton, hwDanger, hwSurface, hwGlassBorder, onAccentColor, withAlpha, reloadAppTheme, resolvePageBackground, topBarGlassColor, resolvePrimaryColor, resolvePrimaryButtonColor, resolveGlassBorderColor } from '../utils/DesignTokens';
import { IconCircleButton } from '../components/IconCircleButton';
import { AppBackground } from '../components/AppBackground';
import { SettingsStore } from '../common/SettingsStore';
import { AppServices } from '../common/AppServices';
import { cardGlassEffect, cardGlassBorderColor, cardGlassShadow } from '../utils/SystemMaterial';
import { CardSurface } from '../components/CardSurface';
import { AccentColorSentinel } from '../components/MaterialCard';
import { parseTransportMode } from '../quickshare/model/TransportPolicy';
import { GalleryAutoSaveSettingRow } from '../components/GalleryAutoSaveSettingRow';

@Component
export struct SettingsPage {
  /** 主题色变化时触发重建，让 HwColor.primary 与选中态取到新色值 */
  @StorageProp('accentColor') @Watch('onAccentColorChanged') accentColor: string = '';
  /** 页面底色（由 applyAppTheme 发布）。直接读 HwColor.background 登记不上依赖 */
  @StorageProp('pageBackground') pageBackground: string = '';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageLink('beautifulCards') beautifulCards: boolean = false;
  @StorageLink('classicCards') classicCards: boolean = false;
  @StorageLink('cardShadowBorder') cardShadowBorder: boolean = true;
  @StorageLink('experimentalCards') experimentalCards: boolean = false;
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
  /** Quick Share 传输方式（三态）：auto 自动探测 / lan 仅局域网 / direct WLAN 直连优先。 */
  @State quickshareTransport: string = 'auto';
  @State btMac: string = '';
  @State wifiUpgradeTcp: boolean = false;
  @State encryptionEnabled: boolean = true;
  @State receivePin: string = '';
  @State keepAlive: boolean = true;
  // 与 EntryAbility 预加载的 AppStorage 同步，方便其它页面/服务读取同一状态。
  @StorageLink('dynamicPhotoEnabled') dynamicPhotoEnabled: boolean = false;
  /** 「默认通用动态图片格式」：认不出对端品牌时动态图片按哪种格式发送。 */
  @StorageLink('defaultLivePhotoFormat') defaultLivePhotoFormat: string = 'android';
  /** 「HDR照片转换为HDR Vivid格式」（默认关）。 */
  @StorageLink('hdrVividEnabled') hdrVividEnabled: boolean = false;
  /** 「照片EXIF信息保留」（默认开）。 */
  @StorageLink('photoExifKeep') photoExifKeep: boolean = true;
  /** 「HDR转换优先重编码」（默认关）：打开后不走系统 API，直接无损换壳。 */
  @StorageLink('hdrSkipSystemReencode') hdrSkipSystemReencode: boolean = false;
  /** 「动态图片/HDR图片不保存至下载文件夹」（默认关）。 */
  @StorageLink('skipDownloadCopyForGalleryPhotos') skipDownloadCopyForGalleryPhotos: boolean = false;

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
      this.quickshareTransport = settings.quickshareTransport ?? (settings.quickshareWlanDirect ? 'direct' : 'auto');
      this.btMac = settings.btMac;
      this.wifiUpgradeTcp = settings.wifiUpgradeTcp;
      this.encryptionEnabled = settings.encryptionEnabled !== false;
      this.receivePin = settings.receivePin ?? '';
      this.keepAlive = settings.keepAlive !== false;
      this.dynamicPhotoEnabled = settings.dynamicPhotoEnabled === true;
      this.defaultLivePhotoFormat = settings.defaultLivePhotoFormat !== undefined
        && settings.defaultLivePhotoFormat.length > 0
        ? settings.defaultLivePhotoFormat
        : 'android';
      this.hdrVividEnabled = settings.hdrVividEnabled === true;
      this.photoExifKeep = settings.photoExifKeep !== false;
      this.hdrSkipSystemReencode = settings.hdrSkipSystemReencode === true;
      this.skipDownloadCopyForGalleryPhotos = settings.skipDownloadCopyForGalleryPhotos === true;
    });
  }

  private persist(): void {
    const context = getContext(this) as common.UIAbilityContext;
    SettingsStore.save(context, {
      alias: this.alias.length > 0 ? this.alias : '羊绒互传',
      requirePin: this.requirePin,
      alwaysVisible: this.alwaysVisible,
      quickshareWlanDirect: this.quickshareTransport === 'direct',
      quickshareTransport: parseTransportMode(this.quickshareTransport),
      btMac: this.btMac.trim(),
      wifiUpgradeTcp: this.wifiUpgradeTcp,
      encryptionEnabled: this.encryptionEnabled,
      receivePin: this.receivePin.trim(),
      keepAlive: this.keepAlive,
      dynamicPhotoEnabled: this.dynamicPhotoEnabled,
      defaultLivePhotoFormat: this.defaultLivePhotoFormat,
      hdrVividEnabled: this.hdrVividEnabled,
      photoExifKeep: this.photoExifKeep,
      hdrSkipSystemReencode: this.hdrSkipSystemReencode,
      skipDownloadCopyForGalleryPhotos: this.skipDownloadCopyForGalleryPhotos
    });
  }

  @Builder
  backBar() {
    Row({ space: 12 }) {
      IconCircleButton({
        symbol: $r('sys.symbol.chevron_left'),
        glass: true,
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
    .backgroundEffect({ radius: 12, color: topBarGlassColor(this.isDarkMode) })
  }

  @Builder
  aliasCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 8 }) {
        Text('设备名称')
          .fontSize(13)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('设备名称'))
          .fontWeight(this.appFontWeight())
          .width('100%')
        TextInput({ text: this.alias, placeholder: '设备名称' })
          .caretColor(this.accentOrPrimary())
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
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  pinRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text($r('app.string.settings_verify_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('传输前要求PIN验证'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_verify_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('双方显示相同PIN，确认后传输，防止中间人攻击'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.requirePin })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.requirePin = value;
            this.persist();
          })
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  visibleRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('LocalSend 可见性')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('LocalSend 可见性'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_visible_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('让附近的 LocalSend 设备发现本机。'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.alwaysVisible })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.alwaysVisible = value;
            this.persist();
          })
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  /**
   * 传输方式三态芯片（与外观设置页的 darkModeChip 同构：自绘底色 + 主题色选中）。
   * 用芯片而不是开关：auto/lan/direct 是三个并列语义，开关只能表达两态。
   */
  @Builder
  transportChip(mode: string, label: string) {
    Text(label)
      .fontSize(13)
      .fontFamily(this.appFontFamily(label))
      .fontWeight(this.appFontWeight())
      .fontColor(this.quickshareTransport === mode
        ? onAccentColor(this.accentOrPrimary()) : hwTextPrimary(this.isDarkMode))
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(HwRadius.pill)
      .backgroundColor(this.quickshareTransport === mode
        ? this.accentOrPrimary() : withAlpha(HwColor.textPrimary, 0.06))
      .border({ width: 1, color: this.quickshareTransport === mode
        ? Color.Transparent : resolveGlassBorderColor(this.isDarkMode, this.accentOrPrimary()) })
      .onClick((): void => {
        this.quickshareTransport = mode;
        this.quickshareWlanDirect = mode === 'direct';
        this.persist();
      })
  }

  @Builder
  wlanDirectRow() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: HwSpace.md }) {
        Column({ space: 4 }) {
          Text('Quick Share 传输方式')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontFamily(this.appFontFamily('Quick Share 传输方式'))
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_transport_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('自动：发送前探测对端是否可达，不可达才走蓝牙引导 + WLAN 直连；仅局域网：不建立 WLAN 直连；WLAN 直连：优先蓝牙引导 + Wi-Fi Direct'))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')

        Row({ space: HwSpace.sm }) {
          this.transportChip('auto', '自动')
          this.transportChip('lan', '仅局域网')
          this.transportChip('direct', 'WLAN 直连')
        }
        .width('100%')
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  btMacCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 8 }) {
        Text($r('app.string.settings_bt_title'))
          .fontSize(13)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('Windows Nearby 蓝牙 MAC 地址'))
          .fontWeight(this.appFontWeight())
          .width('100%')
        TextInput({ text: this.btMac, placeholder: 'AA:BB:CC:DD:EE:FF' })
          .caretColor(this.accentOrPrimary())
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
        Text($r('app.string.settings_bt_description'))
          .fontSize(11)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontFamily(this.appFontFamily('用于接收 Windows 发送的文件。Windows 通过该地址用蓝牙连接手机；请在手机 设置→关于本机→状态信息 中找到“蓝牙地址”填入。'))
          .fontWeight(this.appFontWeight())
          .width('100%')
          .lineHeight(15)
        if (this.btMac.trim().length === 0) {
          Text($r('app.string.settings_bt_missing'))
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
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  wifiUpgradeRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text($r('app.string.settings_wifi_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_wifi_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.wifiUpgradeTcp })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.wifiUpgradeTcp = value;
            this.persist();
          })
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  receivePinCard() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 8 }) {
        Text($r('app.string.settings_pin_title'))
          .fontSize(13)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontWeight(this.appFontWeight())
          .width('100%')
        TextInput({ text: this.receivePin, placeholder: '留空表示不要求 PIN' })
          .caretColor(this.accentOrPrimary())
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
        Text($r('app.string.settings_pin_description'))
          .fontSize(11)
          .fontColor(hwTextSecondary(this.isDarkMode))
          .fontWeight(this.appFontWeight())
          .width('100%')
          .lineHeight(15)
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  encryptionRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text($r('app.string.settings_encryption_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_encryption_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.encryptionEnabled })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.encryptionEnabled = value;
            this.persist();
          })
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  keepAliveRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text($r('app.string.settings_background_title'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(hwTextPrimary(this.isDarkMode))
          Text($r('app.string.settings_background_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontWeight(this.appFontWeight())
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.keepAlive })
          .selectedColor(this.accentOrPrimary())
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
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  /** 「HDR照片转换为HDR Vivid格式」开关（默认关）。 */
  @Builder
  hdrVividRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_hdr_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('HDR照片转换为HDR Vivid格式'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_hdr_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('发送带增益图'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.hdrVividEnabled })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.hdrVividEnabled = value;
            this.persist();
          })
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  /** 「照片EXIF信息保留」开关（默认开）。 */
  @Builder
  exifKeepRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_exif_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('照片EXIF信息保留'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_exif_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('转换 HDR 照片时保留原始 EXIF'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.photoExifKeep })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.photoExifKeep = value;
            this.persist();
          })
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  /** 「HDR转换优先重编码」（默认关，仅 HDR 转换打开时显示）：打开后不走系统 API，直接无损换壳。 */
  @Builder
  hdrPreferReencodeRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_hdr_original_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('HDR转换优先重编码'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_hdr_original_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('打开后不再走系统 API 重编码'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.hdrSkipSystemReencode })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.hdrSkipSystemReencode = value;
            this.persist();
          })
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  /** 「动态图片/HDR图片不保存至下载文件夹」（默认关）。 */
  @Builder
  skipDownloadCopyRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_dynamic_download_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('动态图片/HDR图片不保存至下载文件夹'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_dynamic_download_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('接收到的动态照片（含 HDR）已经保存进相册时'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.skipDownloadCopyForGalleryPhotos })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.skipDownloadCopyForGalleryPhotos = value;
            this.persist();
          })
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  /** 「默认通用动态图片格式」：认不出对端品牌时按哪种格式发送（仅 Beta 开关打开时显示）。 */
  @Builder
  fallbackLivePhotoFormatRow() {
    CardSurface({ radius: HwRadius.card }) {
      Column({ space: 10 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_dynamic_format_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('默认通用动态图片格式'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_dynamic_format_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('识别不出对端品牌时'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        Row({ space: 10 }) {
          this.fallbackFormatChip('Apple 实况照片', 'apple')
          this.fallbackFormatChip('Android 标准动态照片', 'android')
          Blank()
        }
        .width('100%')
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  fallbackFormatChip(label: string, value: string) {
    Text(label)
      .fontSize(13)
      .fontWeight(this.defaultLivePhotoFormat === value ? FontWeight.Medium : FontWeight.Regular)
      .fontFamily(this.appFontFamily(label))
      .fontColor(this.defaultLivePhotoFormat === value
        ? onAccentColor(this.accentOrPrimary()) : hwTextSecondary(this.isDarkMode))
      .padding({ left: 14, right: 14, top: 8, bottom: 8 })
      .borderRadius(HwRadius.pill)
      .backgroundColor(this.defaultLivePhotoFormat === value
        ? resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary())
        : Color.Transparent)
      .border({
        width: 1,
        color: this.defaultLivePhotoFormat === value
          ? resolvePrimaryButtonColor(this.isDarkMode, this.accentOrPrimary())
          : resolveGlassBorderColor(this.isDarkMode, this.accentOrPrimary())
      })
      .onClick(() => {
        if (this.defaultLivePhotoFormat !== value) {
          this.defaultLivePhotoFormat = value;
          this.persist();
        }
      })
  }

  /** 「Beta」小标：本轮新增的实验性设置项统一用它（样式必须与主页设置页完全一致）。 */
  @Builder
  betaBadge() {
    Text('Beta')
      .fontSize(10)
      .fontWeight(FontWeight.Medium)
      .fontFamily(this.appFontFamily('Beta'))
      // 主题色底上的字色按深浅自动取黑/白
      .fontColor(onAccentColor(this.accentOrPrimary()))
      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
      .borderRadius(6)
      .backgroundColor(resolvePrimaryColor(this.isDarkMode, this.accentOrPrimary()))
  }

  @Builder
  dynamicPhotoRow() {
    CardSurface({ radius: HwRadius.card }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text($r('app.string.settings_dynamic_title'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontFamily(this.appFontFamily('动态图片传输'))
              .fontColor(hwTextPrimary(this.isDarkMode))
            this.betaBadge()
          }
          Text($r('app.string.settings_dynamic_description'))
            .fontSize(12)
            .fontColor(hwTextSecondary(this.isDarkMode))
            .fontFamily(this.appFontFamily('发送时自动识别动态图片'))
            .fontWeight(this.appFontWeight())
            .lineHeight(16)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.dynamicPhotoEnabled })
          .selectedColor(this.accentOrPrimary())
          .onChange((value: boolean) => {
            this.dynamicPhotoEnabled = value;
            this.persist();
          })
      }
      .width('100%')
      .padding(HwSpace.lg)
      .borderRadius(HwRadius.card)
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
    }
  }

  @Builder
  appearanceRow() {
    CardSurface({ radius: HwRadius.control }) {
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
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick(() => {
        this.persist();
        router.pushUrl({ url: 'pages/AppearanceSettingsPage' }).catch((error: BusinessError): void => {
          Lg.w('Appearance route failed: ' + error.message);
        });
      })
    }
  }

  @Builder
  aboutRow() {
    CardSurface({ radius: HwRadius.control }) {
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
      .backgroundColor(Color.Transparent)
      .backgroundEffect(cardGlassEffect(this.beautifulCards, this.classicCards, this.isDarkMode, this.experimentalCards))
      .border({ width: 1, color: cardGlassBorderColor(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards) })
      .clip(true)
      .shadow(cardGlassShadow(this.beautifulCards, this.cardShadowBorder, this.isDarkMode, this.experimentalCards))
      .onClick(() => {
        this.persist();
        router.pushUrl({ url: 'pages/AboutPage' }).catch((error: BusinessError): void => {
          Lg.w('About route failed: ' + error.message);
        });
      })
    }
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
    Stack({ alignContent: Alignment.TopStart }) {
      // 主题色依赖：切色时让整页重新求值（零尺寸，不参与布局）
      AccentColorSentinel()
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
              this.dynamicPhotoRow()
              // 只在「动态图片传输(Beta)」打开时显示（与主页设置页保持一致）。
              if (this.dynamicPhotoEnabled) {
                this.fallbackLivePhotoFormatRow()
              }
              this.hdrVividRow()
              // 「HDR转换优先重编码」只在 HDR 转换打开时显示。
              if (this.hdrVividEnabled) {
                this.hdrPreferReencodeRow()
              }
              this.exifKeepRow()
              this.skipDownloadCopyRow()
              GalleryAutoSaveSettingRow()
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
    .backgroundColor(resolvePageBackground(this.isDarkMode, this.pageBackground))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
