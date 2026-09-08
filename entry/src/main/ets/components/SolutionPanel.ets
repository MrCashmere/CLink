import {
  HwRadius,
  HwSpace,
  hwTextPrimary,
  hwTextSecondary,
  hwPrimary,
  hwGlassSurface,
  hwGlassBorder
} from '../utils/DesignTokens';
import { isApi26OrAbove, immersiveMaterialModifier, legacyMaterialModifier } from '../utils/SystemMaterial';

export interface SolutionQA {
  qLabel: string;
  question: string;
  aLabel: string;
  answer: string;
}

export interface SolutionGroup {
  title: string;
  items: SolutionQA[];
}

/**
 * 「解决方案」问答内容：关于页与聚合页标题栏共用同一份数据，改文案只需改这里。
 */
export const SOLUTION_GROUPS: SolutionGroup[] = [
  {
    title: 'Quick Share连接，传输问题',
    items: [
      {
        qLabel: 'Q1', question: '已经搜索到设备，但是无法发送/接收文件怎么办？',
        aLabel: 'A1', answer: '可能是有部分网络工具干扰了环境，启动或关闭它们试试。'
      },
      {
        qLabel: 'Q2', question: '分享需要连接到互联网吗？',
        aLabel: 'A2', answer: '不需要。'
      }
    ]
  },
  {
    title: 'Windows附近分享连接，传输问题',
    items: [
      {
        qLabel: 'Q1', question: '搜索不到设备怎么办？',
        aLabel: 'A1', answer: 'Windows设置中将就近共享设置改为“附近的所有人”。'
      },
      {
        qLabel: 'Q2', question: '已经搜索到设备，但是无法发送/接收文件怎么办？',
        aLabel: 'A2', answer:
          '第一步确认：Windows端网络和 Internet 设置中当前使用的网络是“专用网络”而不是公用网络；\n' +
          '第二步 PowerShell 输入：\n' +
          'New-NetFirewallRule -DisplayName "Allow TCP 5040" -Direction Inbound -Protocol TCP -LocalPort 5040 -Action Allow\n' +
          'New-NetFirewallRule -DisplayName "Allow UDP 5050" -Direction Inbound -Protocol UDP -LocalPort 5050 -Action Allow'
      }
    ]
  },
  {
    title: 'LocalSend连接，传输问题',
    items: [
      {
        qLabel: 'Q', question: '连接/发送失败怎么办？',
        aLabel: 'A', answer: '关闭对端的“PIN码”和“加密”。'
      }
    ]
  }
];

/**
 * 「解决方案」面板：可折叠的分组问答列表。
 *
 * 关于页与聚合页标题栏的「?」按钮共用本组件（均放在 bindSheet 内），
 * 展开状态是组件内部状态，弹窗关闭销毁后自动复位。
 */
@Component
export struct SolutionPanel {
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('fontMode') fontMode: string = 'system';
  @StorageLink('fontFamilyEn') fontFamilyEn: string = 'system';
  @StorageLink('fontFamilyZh') fontFamilyZh: string = 'system';
  @StorageLink('fontWeightMode') fontWeightMode: string = 'system';
  @StorageLink('fontWeightValue') fontWeightValue: number = 400;
  @StorageLink('immersiveLightEnabled') immersiveLightEnabled: boolean = true;
  /** 展开的解决方案卡片索引，-1 表示无展开。 */
  @State expandedSolution: number = -1;

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

  @Builder
  qaRow(label: string, content: string, isQuestion: boolean) {
    Row({ space: 8 }) {
      Text(label)
        .fontFamily(this.appFontFamily(label))
        .fontWeight(FontWeight.Medium)
        .fontSize(13)
        .fontColor(isQuestion ? hwPrimary(this.isDarkMode) : hwTextSecondary(this.isDarkMode))
        .width(44)
      Column({ space: 2 }) {
        ForEach(content.split('\n'), (line: string) => {
          Text(line)
            .fontFamily(this.appFontFamily(line))
            .fontWeight(this.appFontWeight())
            .fontSize(13)
            .fontColor(isQuestion ? hwTextPrimary(this.isDarkMode) : hwTextSecondary(this.isDarkMode))
            .lineHeight(20)
            .width('100%')
        }, (line: string, index: number) => label + ':' + line + ':' + index)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  solutionCard(index: number, group: SolutionGroup) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(group.title)
          .fontFamily(this.appFontFamily(group.title))
          .fontWeight(this.appFontWeight())
          .fontSize(15)
          .fontColor(hwTextPrimary(this.isDarkMode))
          .layoutWeight(1)
        SymbolGlyph(this.expandedSolution === index ? $r('sys.symbol.chevron_up') : $r('sys.symbol.chevron_down'))
          .fontSize(14)
          .fontColor([hwTextSecondary(this.isDarkMode)])
      }
      .width('100%')

      if (this.expandedSolution === index) {
        Column({ space: 10 }) {
          ForEach(group.items, (item: SolutionQA) => {
            Column({ space: 6 }) {
              this.qaRow(item.qLabel, item.question, true)
              this.qaRow(item.aLabel, item.answer, false)
            }
            .width('100%')
          }, (item: SolutionQA) => item.qLabel + ':' + item.aLabel)
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding(HwSpace.lg)
    .borderRadius(HwRadius.card)
    .backgroundColor(hwGlassSurface(this.isDarkMode))
    .attributeModifier(this.immersiveLightEnabled && isApi26OrAbove() ? immersiveMaterialModifier : legacyMaterialModifier)
    .border({ width: 1, color: hwGlassBorder(this.isDarkMode) })
    .clip(true)
    .onClick(() => {
      this.expandedSolution = this.expandedSolution === index ? -1 : index;
    })
  }

  build() {
    Column({ space: 12 }) {
      Text('解决方案')
        .fontFamily(this.appFontFamily('解决方案'))
        .fontWeight(this.appFontWeight())
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(hwTextPrimary(this.isDarkMode))
        .width('100%')

      ForEach(SOLUTION_GROUPS, (group: SolutionGroup, index: number) => {
        this.solutionCard(index, group)
      }, (group: SolutionGroup, index: number) => group.title + ':' + index)
    }
    .width('100%')
    .padding({ left: HwSpace.lg, right: HwSpace.lg, top: 16, bottom: 32 })
  }
}
