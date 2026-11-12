import { immersiveCardsActive, pressLightColor } from '../utils/SystemMaterial';
import { HwRadius, withAlpha } from '../utils/DesignTokens';
import { MaterialCardLayer } from './MaterialCard';

/**
 * 卡片表面容器：内容区卡片的「背板」外壳，负责把系统沉浸光感材质贴到卡片下面，
 * 并提供按压流光（跟着手指走的一小团柔光，**只在卡片内**）。
 *
 * ⚠️ **内容不能为空**：内层承载层是 `ToggleType.Button`，该类型有 28vp 的默认高度，
 * 内容为空时它仍会把外壳撑出约 28vp（表现为「卡片之间莫名多出一段间距」）。
 * 需要条件显示时把 `if` 写在 CardSurface **外面**：
 * ```ets
 * if (this.items.length > 0) {
 *   CardSurface({ radius: HwRadius.card }) { ... }
 * }
 * ```
 *
 * ─────────────────────────────────────────────────────────────────────────
 * 为什么卡片需要一层外壳
 * ─────────────────────────────────────────────────────────────────────────
 * HarmonyOS 7（API 26）起，targetSdkVersion >= 26.0.0 时沉浸光感有生效范围约束：
 * 布局容器（Column/Row 等）在内容区设置 `systemMaterial` 不生效（系统日志
 * `Material inactive: out of scope. Use component in navigation title bar or Tabbar.`），
 * 只有「弹窗类组件与弹窗类接口」和「按钮与选择类组件（Slider、Toggle、Select）」
 * 能在页面内全部区域生效。
 *
 * 所以卡片用 **Toggle（ToggleType.Button）** 作为背板（见 components/MaterialCard.ets
 * 的 MaterialCardLayer）：Toggle 是官方明确列出「可在页面内全部区域生效」的组件，
 * 且 ToggleType.Button 允许包含子组件。
 *
 * 用法保持不变（卡片自身的 width/padding/borderRadius/glass 等仍写在卡片根节点上）：
 * ```ets
 * CardSurface({ radius: HwRadius.card }) {
 *   Row({ space: 12 }) { ... }
 *     .width('100%')
 *     .padding(HwSpace.lg)
 *     .borderRadius(HwRadius.card)
 *     .backgroundColor(Color.Transparent)
 *     .backgroundEffect(cardGlassEffect(..., this.experimentalCards))
 *     .border({ width: 1, color: cardGlassBorderColor(...) })
 *     .clip(true)
 *     .shadow(cardGlassShadow(...))
 * }
 * ```
 * 四个 glass helper 在沉浸光感生效时会统一返回「无效果」，把表面完全让给系统材质；
 * 不生效时（低版本 / 开关关闭 / 材质构造失败）保持原有毛玻璃外观。
 *
 * ─────────────────────────────────────────────────────────────────────────
 * 按压流光（两个开关）
 * ─────────────────────────────────────────────────────────────────────────
 *   - 「主题色流光」`immersivePressGlow`（默认开）：流光用主题色，关闭回到系统白光；
 *   - 「卡片流光触感」`cardGlowTouch`（默认关）：**关 = 按压卡片一点光都不出现**，
 *     开 = 手指底下那团跟手柔光。
 */

/**
 * 流光光晕的半径（vp）。
 *
 * 流光不是描边：它是**跟着手指走的一小团柔光**，手指滑到哪、光就落在哪。
 * 半径必须收着给：130 那种尺寸会盖住大半张卡片，看起来像「整卡高亮选中」；
 * 64 大致是一枚指腹的范围。
 */
const PRESS_GLOW_RADIUS: number = 64;
/**
 * 光晕中心浓度。
 * 光本身不该是一块实色：压到 0.3 出头是「照亮玻璃表面」，再浓就变成往卡片上刷了一层主题色。
 */
const PRESS_GLOW_ALPHA: number = 0.32;

@Component
export struct CardSurface {
  /** 卡片圆角，需与卡片根节点的 borderRadius 一致。 */
  @Prop radius: number = HwRadius.card;
  /** 全局沉浸光感开关：决定用材质背板还是透传。 */
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  /** 卡片沾色叠加层颜色（空串表示不沾色）。由 applyAppTheme 按主题色发布 */
  @StorageProp('cardTintColor') cardTint: string = '';
  /** 主题色：切色时本组件重建，流光颜色才会跟着换 */
  @StorageProp('accentColor') accentColor: string = '';
  /** 主题色流光开关 */
  @StorageProp('immersivePressGlow') pressGlowSwitch: boolean = true;
  /** 卡片流光触感开关（默认关） */
  @StorageProp('cardGlowTouch') glowTouchEnabled: boolean = false;
  @BuilderParam content: () => void = this.emptyContent;

  /**
   * 流光状态：`glowOn` 手指是否落在卡片上，`glowX/glowY` 光斑中心（相对卡片左上角，vp）。
   * 用 `@State`：它们是渲染属性，必须触发重绘才会出现、移动、消失。
   */
  @State glowOn: boolean = false;
  @State glowX: number = 0;
  @State glowY: number = 0;

  /**
   * 坐标换算用的一组普通字段（不参与渲染，所以不用 @State）。
   *
   * 光要**跟着手指在屏幕上走**，而触摸事件给的是窗口坐标：必须减去卡片自身
   * 在窗口中的原点才能换算成卡片内坐标。
   *   - `cardWinX/Y`：卡片左上角在窗口中的位置。按下那一瞬由 `windowX - x` 反推
   *     （这时组件内坐标一定准），之后靠 `onAreaChange` 的**位移增量**维护——
   *     列表滚动时卡片在动，增量必须跟上，否则手指不动、页面滚动，光斑会黏在卡片原处。
   *   - `lastTouchWinX/Y`：最近一次触摸的窗口坐标，卡片位置变了要拿它重算。
   *   - `lastAreaX/Y` + `areaReady`：上一次 onAreaChange 报的全局坐标，用来求增量。
   *     只取增量、不用绝对值：`globalPosition` 的原点与 `windowX/Y` 未必是同一套，
   *     但两者在滚动中的**变化量**必然一致。
   */
  private cardWinX: number = 0;
  private cardWinY: number = 0;
  private lastTouchWinX: number = 0;
  private lastTouchWinY: number = 0;
  private lastAreaX: number = 0;
  private lastAreaY: number = 0;
  private areaReady: boolean = false;

  @Builder
  emptyContent() {
  }

  /** 沉浸光感是否生效：应用开关打开 + 系统能力与材质都可用 */
  private materialActive(): boolean {
    return this.immersiveLightEnabled && immersiveCardsActive();
  }

  /** 主题色流光当前是否可用（开关 + 主题色都在）。空串表示不可用 */
  private glowAccent(): string {
    return pressLightColor(this.pressGlowSwitch, this.accentColor);
  }

  /** 是否有光可画（按下 + 材质生效 + 主题色流光可用） */
  private glowVisible(): boolean {
    return this.glowOn && this.materialActive() && this.glowAccent().length > 0;
  }

  /** 跟手光斑：要求「卡片流光触感」打开（关掉时按压卡片一点光都不出现） */
  private touchGlowVisible(): boolean {
    return this.glowVisible() && this.glowTouchEnabled;
  }

  /**
   * 跟手滑动的流光。
   *
   * 触摸坐标用 `touches[0].x/y`——它相对**绑定 onTouch 的组件**（本外壳的 Stack），
   * 正好就是光晕层要用的坐标系。
   * Move 也要处理：流光之所以像「光」而不像「按下高亮」，就在于手指滑动时它会跟着走。
   * 抬起与取消都必须熄灭，否则会留一块不会消失的光斑。
   */
  private updatePressGlow(event: TouchEvent): void {
    if (this.glowAccent().length === 0 || !this.materialActive()) {
      return;
    }
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      this.glowOn = false;
      return;
    }
    if (event.type !== TouchType.Down && event.type !== TouchType.Move) {
      return;
    }
    if (event.touches.length === 0) {
      return;
    }
    const touch = event.touches[0];
    if (event.type === TouchType.Down) {
      // 按下这一瞬 `x/y` 一定是相对当前卡片位置的准确值，用它反推卡片原点
      this.cardWinX = touch.windowX - touch.x;
      this.cardWinY = touch.windowY - touch.y;
    }
    this.lastTouchWinX = touch.windowX;
    this.lastTouchWinY = touch.windowY;
    this.syncGlowPosition();
    this.glowOn = true;
  }

  /** 用最近一次触摸的窗口坐标重算光斑位置（手指不动、页面在滚时也要调） */
  private syncGlowPosition(): void {
    this.glowX = this.lastTouchWinX - this.cardWinX;
    this.glowY = this.lastTouchWinY - this.cardWinY;
  }

  /**
   * 光晕的径向渐变色标：由内到外三档淡出。
   * 只用一档实色会得到一个硬边圆盘，看着像贴纸而不是光。
   */
  private glowGradientColors(): Array<[ResourceColor, number]> {
    const accent: string = this.glowAccent();
    return [
      [withAlpha(accent, PRESS_GLOW_ALPHA), 0],
      [withAlpha(accent, PRESS_GLOW_ALPHA * 0.55), 0.42],
      [withAlpha(accent, PRESS_GLOW_ALPHA * 0.18), 0.72],
      [Color.Transparent, 1]
    ];
  }

  /**
   * 跟手流光层：尺寸跟随卡片（matchParent），只覆盖手指周围一小片。
   *
   * 压在材质**之上**、内容**之下**：光打在玻璃表面上，到卡片圆角边缘被裁断，
   * 接上材质自己那圈边缘折射。实测**不能放在材质之下**——沉浸光感材质不采样
   * 同一 Stack 里的兄弟节点，光会被整层盖住，真机上完全看不见。
   *
   * ⚠️ **光只留在卡片内**：这一层自带 `borderRadius`，到圆角处被收住。
   * 刻意**不做**「溢出到卡间缝隙」的环境光——卡片之外（页面底色、卡与卡的缝）没有
   * 沉浸光感材质，在那里画光等于在非沉浸光感区域凭空出现一块亮斑，
   * 观感是「糊了一块」而不是「玻璃被照亮」。
   */
  @Builder
  pressGlowLayer() {
    if (this.touchGlowVisible()) {
      Column()
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        // 圆角必须自己给：外壳为了不裁掉材质自带的投影没有设 clip
        .borderRadius(this.radius)
        .radialGradient({
          center: [this.glowX, this.glowY],
          radius: PRESS_GLOW_RADIUS,
          colors: this.glowGradientColors()
        })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
  }

  /** 卡片沾色层：叠在材质之上、内容之下，整块方形底色必须自己带圆角 */
  @Builder
  cardTintLayer() {
    if (this.cardTint.length > 0) {
      Column()
        // 必须 matchParent，不能写 width/height('100%')：百分比在 Stack 内按
        // **父级可用尺寸**解析，高度会撑到容器满高、把卡片顶大。
        .width(LayoutPolicy.matchParent)
        .height(LayoutPolicy.matchParent)
        .borderRadius(this.radius)
        .backgroundColor(this.cardTint)
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
    }
  }

  build() {
    if (this.materialActive()) {
      Stack() {
        // ① 材质承载层（ToggleType.Button）
        MaterialCardLayer({ layerRadius: this.radius })
        // ② 沾色层：必须在材质之上（外壳底色在材质生效时是透明的，混进底色看不见）
        this.cardTintLayer()
        // ③ 跟手光斑：材质之上、内容之下
        this.pressGlowLayer()
        // ④ 内容（卡片自己的 glass helper 在材质生效时已返回「无效果」）
        Column() {
          this.content()
        }
        .width('100%')
      }
      .width('100%')
      // 刻意**不设 clip(true)**：会连材质自带的投影一起裁掉。
      // 需要裁切的每一层都自己带圆角（材质层、沾色层、光斑层），效果等价，
      // 而且光斑只能落在卡片内——不会溢到没有沉浸光感的区域。
      .onAreaChange((_oldArea: Area, newArea: Area): void => {
        const gx: number = typeof newArea.globalPosition.x === 'number' ? newArea.globalPosition.x : this.lastAreaX;
        const gy: number = typeof newArea.globalPosition.y === 'number' ? newArea.globalPosition.y : this.lastAreaY;
        if (this.areaReady) {
          // 只取增量：卡片被滚动带走时光斑要跟着手指重算，不然会黏在卡片原处
          this.cardWinX += gx - this.lastAreaX;
          this.cardWinY += gy - this.lastAreaY;
          if (this.glowOn) {
            this.syncGlowPosition();
          }
        }
        this.lastAreaX = gx;
        this.lastAreaY = gy;
        this.areaReady = true;
      })
      .onTouch((event: TouchEvent): void => {
        this.updatePressGlow(event);
      })
    } else {
      // 沉浸光感不可用：透传内容，卡片保持原有毛玻璃外观。
      // 沾色层垫在内容之下（卡片的 glass 底色带透明度，沾色会透出来）。
      Stack() {
        this.cardTintLayer()
        Column() {
          this.content()
        }
        .width('100%')
      }
      .width('100%')
    }
  }
}
