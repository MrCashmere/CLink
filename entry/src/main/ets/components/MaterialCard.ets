import { applyMaterialCarrier, isApi26OrAbove } from '../utils/SystemMaterial';
import { HwGlassCardColor, HwRadius } from '../utils/DesignTokens';

/**
 * 沉浸光感承载层与配套组件。
 *
 * 为什么需要「承载层」：API 26 / targetSdkVersion >= 26 后，非选择类组件
 * （Column/Row 等布局容器）在**页面内容区**设置 `systemMaterial` 不生效
 * （系统日志 `Material inactive: out of scope`），只有弹窗类、
 * 以及按钮与选择类（Slider / Toggle / Select）能在全区域生效。
 *
 * 而 `ToggleType.Button` 既能全区域生效、又能包含子组件
 * （SDK toggle.d.ts：*"This component can contain child components only when ToggleType is set to Button."*），
 * 所以全仓统一用 **Toggle 当「看不见的画布」**：让它去画材质，内容叠在它上面。
 *
 * 五条属性缺一不可（少任何一条都会出问题）：
 *   ① `matchParent`      尺寸塌成 0 就画不出材质；
 *   ② `borderRadius`     否则 Toggle 会画出自己的按钮图形（内嵌的小圆角 + 描边）；
 *   ③ `Color.Transparent` 不透明底色会垫在材质之下叠出灰感甚至完全遮住；
 *   ④ `enabled(false)` 等 承载层抢走焦点与点击会让内容点不动；
 *   ⑤ `attributeModifier` 放在属性链**最末**，否则材质被后面的样式属性覆盖。
 */

/**
 * 卡片 / 面板 / 按钮的沉浸光感承载层（ToggleType.Button）。
 *
 * 用法：放进 `Stack` 里做最底一层，内容作为兄弟节点叠在其上。
 * 承载层自身不参与交互（`enabled(false)` + `hitTestBehavior(None)`），
 * 需要「按压流光」的元件请改用 `interactive` 版本（见 components/IconCircleButton.ets）。
 */
@Component
export struct MaterialCardLayer {
  /** 必须与外壳圆角一致，否则卡片里会出现「更小圆角的内嵌边框」 */
  @Prop layerRadius: Length = HwRadius.card;
  /**
   * 是否让材质自带投影。
   *
   * 材质的 `applyShadow` 默认 true：大卡片上这层投影是加分项，
   * 但小尺寸芯片（筛选、排序、分类切换）上会显得像「按钮背后顶了一层影子」，这类地方传 false。
   */
  @Prop layerShadow: boolean = true;

  build() {
    Toggle({ type: ToggleType.Button, isOn: false })
      // ① 尺寸跟随父级实测尺寸，不能用百分比（百分比按父级**可用**尺寸解析，会把卡片顶大）
      .width(LayoutPolicy.matchParent)
      .height(LayoutPolicy.matchParent)
      // ② 圆角与外壳一致
      .borderRadius(this.layerRadius)
      // ③ 必须显式透明（材质的视觉层级在 backgroundColor 之下）
      .backgroundColor(Color.Transparent)
      // 选中态底色：ToggleType.Button 默认取系统强调色，不设就会「点一下变蓝」
      .selectedColor(Color.Transparent)
      // ④ 只是画布，不参与交互与无障碍
      .enabled(false)
      .focusable(false)
      .accessibilityLevel('no')
      .hitTestBehavior(HitTestMode.None)
      // ⑤ systemMaterial 放在所有样式属性之后
      .attributeModifier({
        applyNormalAttribute: (instance: ToggleAttribute): void => {
          applyMaterialCarrier(instance, false, false, this.layerShadow);
        }
      })
  }
}

/**
 * 半模态弹窗（向上弹出的卡片）的沉浸光感面板。
 *
 * 为什么不能只靠 `bindSheet` 自身的 `systemMaterial`：那个材质挂在**弹窗面板本身**上，
 * 与卡片遇到的是同一堵墙——非选择类组件的 `systemMaterial` 在内容区不生效，
 * 真机表现就是「面板完全没有光感」。所以这里沿用与 CardSurface 完全一致的解法：
 * 用 ToggleType.Button 承载层铺满整个面板，材质由承载层渲染。
 *
 * ⚠️ 调用侧必须给 `bindSheet` 显式设 `backgroundColor: Color.Transparent`
 * （`BindOptions.backgroundColor` 默认是 `Color.White`，会把材质整块盖住）。
 */
@Component
export struct MaterialSheetPanel {
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  @StorageProp('cardSurface') cardSurface: string = '';
  /** 面板上方两角的圆角 */
  @Prop panelRadius: number = HwRadius.card;
  /** 内容内边距。传 0 则由内容自己控制留白 */
  @Prop panelPadding: Length = 0;
  @BuilderParam panelContent: () => void = this.emptyPanel;

  @Builder
  emptyPanel() {
  }

  private materialActive(): boolean {
    return this.immersiveLightEnabled && isApi26OrAbove();
  }

  build() {
    Stack() {
      if (this.materialActive()) {
        MaterialCardLayer({ layerRadius: this.panelRadius })
      }
      Column() {
        this.panelContent()
      }
      .width('100%')
      .height('100%')
      .padding(this.panelPadding)
    }
    .width('100%')
    .height('100%')
    .borderRadius({ topLeft: this.panelRadius, topRight: this.panelRadius, bottomLeft: 0, bottomRight: 0 })
    // 材质生效时必须让出底色，否则底色垫在材质之下会叠出灰感
    .backgroundColor(this.materialActive() ? Color.Transparent
      : (this.cardSurface.length > 0 ? this.cardSurface : HwGlassCardColor.surface))
    .clip(true)
  }
}

/**
 * 主题色依赖标记。
 *
 * `HwColor` 是模块级对象，改属性不会触发任何组件刷新。把本组件放在页面根 `Stack` 的
 * 第一个子节点（零尺寸、不参与布局与命中测试），它读取 `accentColor`，
 * 从而在切换主题色时让整个页面重新求值，页面内所有 `hwPrimary(...)` 才会取到新颜色。
 *
 * 为什么需要它：`@StorageProp` + `@Watch` 只触发回调、**不重新求值组件**；
 * 必须有一个始终渲染的表达式真正读到该值，ArkUI 才会把页面标记为脏并重建。
 *
 * 注意：它能让页面**内容**的表达式重算，但不会让页面根节点自身的属性重新求值——
 * 页面自己的底色仍然要走 `resolvePageBackground(this.isDarkMode, this.pageBackground)`。
 */
@Component
export struct AccentColorSentinel {
  @StorageProp('accentColor') accentColor: string = '';

  build() {
    // 尺寸为 0、不参与命中测试：纯粹用来建立数据依赖
    Row()
      .width(0)
      .height(0)
      .opacity(0)
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')
      .backgroundColor(this.accentColor.length > 0 ? this.accentColor : Color.Transparent)
  }
}
