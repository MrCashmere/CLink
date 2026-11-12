import { hwTextPrimary, topBarButtonGlassColor } from '../utils/DesignTokens';
import { applyMaterialCarrier, isApi26OrAbove, pressLightColor } from '../utils/SystemMaterial';

/**
 * 圆形图标按钮（沉浸光感 + 主题色流光）。
 *
 * 载体必须是 `ToggleType.Button`：真机实测（HarmonyOS 7.0.0.105 / API 26）
 * **普通 `Button` 挂 systemMaterial 不渲染**，而同尺寸的 `ToggleType.Button`
 * 正常出材质（卡片用的就是它）。这是本组件唯一可用的承载形态。
 *
 * 结构：`ToggleType.Button` 作为交互层承载材质并接收触摸，
 * 图标用 `SymbolGlyph` 叠在它上面、设 `hitTestBehavior(HitTestMode.None)` 让触摸穿透，
 * 这样按压与流光都由 Toggle 本体响应。
 *
 * 流光（类 HdsTab 的灵动反馈）来自《沉浸式系统材质视效》：
 *   - `interactive: true`：按压弹性形变，松手自动恢复；
 *   - `lightEffect`：手指触摸时流光跟随，颜色默认白、可按主题色下发（见 pressLightColor）。
 *
 * 两条硬要求（《沉浸光感常见问题》）：
 *   - 材质层级在 `backgroundColor` 之下 → 材质生效时必须显式 `Color.Transparent`；
 *   - `systemMaterial` 要放在其他样式属性之后 → 用 attributeModifier 挂链尾。
 */
@Component
export struct IconCircleButton {
  @Prop buttonSize: number = 40;
  @Prop iconSize: number = 20;
  @Prop buttonEnabled: boolean = true;
  @Prop tint: string = '';
  /**
   * 是否使用玻璃质感外形（透明底 + 毛玻璃 + 细描边）。
   * 用于各页面顶部标题栏的返回键，与标题栏背景保持同一套玻璃参数。
   * 沉浸光感生效时材质接管背板，这层毛玻璃自动让位。
   */
  @Prop glass: boolean = false;
  /**
   * 是否开启交互形变 + 流光（类 HdsTab 的灵动反馈）。
   *
   * 该能力依赖设备算力档位对 `ImmersiveOptions.interactive` / `lightEffect` 的支持。
   * 若开启后发现材质整块消失，说明该设备不支持，把这里改回 `false`（会退回静态材质）。
   */
  @Prop buttonInteractive: boolean = true;
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  /**
   * 主题色流光依赖。
   *
   * 流光的颜色由 `applyMaterialCarrier` 在挂载材质时按主题色下发，
   * 而属性修饰器只在组件重建时才会重新执行。这里订阅主题色与流光开关，
   * 拨动开关或切色时本组件重建一次，流光颜色才会跟着换。
   */
  @StorageProp('accentColor') accentColor: string = '';
  @StorageProp('immersivePressGlow') pressGlowSwitch: boolean = true;
  symbol: Resource = $r('sys.symbol.house');
  onAction: () => void = (): void => {
  };

  private resolvedTint(): string {
    if (this.tint.length > 0) {
      return this.tint;
    }
    return hwTextPrimary(this.isDarkMode);
  }

  /** 沉浸光感是否接管背板：应用开关 + 系统版本 */
  private materialActive(): boolean {
    return this.immersiveLightEnabled && isApi26OrAbove();
  }

  /**
   * 材质承载修饰器。
   *
   * **必须写成方法并在 build 里调用**，不能把对象字面量直接塞进
   * `.attributeModifier({...})`：流光的颜色要在这里现读订阅变量（主题色 + 流光开关），
   * 读发生在渲染期才会被登记成依赖，拨开关或切主题色时本组件才会重建、重新下发带色材质。
   * 写成内联字面量的话闭包体不在渲染期执行，读什么都登记不上。
   */
  private carrierModifier(): AttributeModifier<ToggleAttribute> {
    // 空串 = 不指定颜色，用系统默认白光（关掉「主题色流光」时的观感）
    const lightColor: string = pressLightColor(this.pressGlowSwitch, this.accentColor);
    const interactive: boolean = this.buttonInteractive;
    return {
      applyNormalAttribute: (instance: ToggleAttribute): void => {
        // fallbackBlur 传 false：毛玻璃由下面的 backgroundEffect 自己画，
        // 两者作用在同一个背景滤镜上，同时用会互相覆盖
        applyMaterialCarrier(instance, false, interactive, true, lightColor);
      }
    };
  }

  build() {
    Stack() {
      // 材质 + 交互层：ToggleType.Button
      Toggle({ type: ToggleType.Button, isOn: false })
        .width(this.buttonSize)
        .height(this.buttonSize)
        .borderRadius(this.buttonSize / 2)
        .clip(true)
        // 材质生效时必须显式透明（不透明背景会盖在材质层之上）；
        // 材质不可用时保持原有底色，按钮不会变成「只剩一个图标」
        .backgroundColor(this.materialActive() ? Color.Transparent
          : (this.glass ? Color.Transparent : '#14000000'))
        .backgroundEffect(this.materialActive() || !this.glass
          ? { radius: 0, color: Color.Transparent }
          : { radius: 12, color: topBarButtonGlassColor(this.isDarkMode) })
        .border(this.glass && !this.materialActive()
          ? { width: 1, color: '#33FFFFFF' }
          : { width: 0, color: Color.Transparent })
        // 关掉按压/选中的主题色填充：ToggleType.Button 的选中态默认取主题强调色，
        // 按下时会闪一层色块；isOn 恒为 false 也挡不住这个按压填充。
        .selectedColor(Color.Transparent)
        .enabled(this.buttonEnabled)
        // systemMaterial 放在所有样式属性之后
        .attributeModifier(this.carrierModifier())
        .onChange(() => {
          this.onAction();
        })

      // 图标层：触摸穿透到下面的 Toggle，保证按压与流光响应在材质上
      SymbolGlyph(this.symbol)
        .fontSize(this.iconSize)
        .fontColor([this.resolvedTint()])
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
  }
}
