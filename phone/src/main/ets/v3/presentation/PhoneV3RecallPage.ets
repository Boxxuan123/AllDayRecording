import { PhoneHistoryRecallSection } from './PhoneHistoryRecallSection';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { PhoneV3SessionCard } from '../domain/PhoneV3Models';
import { PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET } from './PhoneV3NativeUi';
@Component
export struct PhoneV3RecallPage {
  @ObjectLink viewModel: PhoneV3ViewModel;
  onOpenSession: (session: PhoneV3SessionCard) => void = (): void => {};
  onOpenPeople: () => void = (): void => {};
  build() {
    Scroll() {
      Column({ space: 12 }) {
        Button('人物与已确认来源身份').height(44).buttonStyle(ButtonStyleMode.TEXTUAL).onClick(this.onOpenPeople)
        Text('按需找回 QQ、微信与录音。模型归纳可选，原文与推测分别展示。').fontSize(13).fontColor($r('app.color.text_secondary'))
        PhoneHistoryRecallSection({ viewModel: this.viewModel, onOpenSession: this.onOpenSession })
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 16, right: 16, top: 8 })
    }.width('100%').height('100%').align(Alignment.TopStart)
      .contentEndOffset(PHONE_V3_FLOATING_TAB_BAR_CONTENT_END_OFFSET)
      .backgroundColor($r('app.color.page_background'))
  }
}
