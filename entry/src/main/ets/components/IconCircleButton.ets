import { hwTextPrimary } from '../utils/DesignTokens';

@Component
export struct IconCircleButton {
  @Prop buttonSize: number = 40;
  @Prop iconSize: number = 20;
  @Prop buttonEnabled: boolean = true;
  @Prop tint: string = '';
  @StorageProp('isDarkMode') isDarkMode: boolean = false;
  symbol: Resource = $r('sys.symbol.house');
  onAction: () => void = (): void => {
  };

  private resolvedTint(): string {
    if (this.tint.length > 0) {
      return this.tint;
    }
    return hwTextPrimary(this.isDarkMode);
  }

  build() {
    Button({ type: ButtonType.Circle, stateEffect: true }) {
      SymbolGlyph(this.symbol)
        .fontSize(this.iconSize)
        .fontColor([this.resolvedTint()])
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
    .backgroundColor('#14000000')
    .enabled(this.buttonEnabled)
    .onClick(() => {
      this.onAction();
    })
  }
}