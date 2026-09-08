import { SettingsPage } from '../view/SettingsPage';

@Entry
@Component
struct SettingsEntry {
  build() {
    Column() {
      SettingsPage()
    }
    .width('100%')
    .height('100%')
  }
}