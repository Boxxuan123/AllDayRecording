import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { PhoneV3AnnotationEditor } from '../domain/PhoneV3AnnotationEditor';
import { phoneV3AnnotationState, phoneV3AnnotationKey } from '../domain/PhoneV3AnnotationState';
import { PhoneV3Utterance } from '../domain/PhoneV3Models';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';
import { phoneV3AbsoluteTime } from './PhoneV3UiFormat';

@Component
export struct PhoneV3AnnotationListPage {
  viewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  @State editor: PhoneV3AnnotationEditor = new PhoneV3AnnotationEditor();
  @Prop scopeTitle: string = '当前范围';
  @Prop @Watch('refreshRows') stateRevision: number = 0;
  @State private selectedOnly: boolean = false;
  @State private query: string = '';
  private scroller: Scroller = new Scroller();
  onOpen: (editor: PhoneV3AnnotationEditor, title: string) => void = (): void => {};
  private refreshRows(): void { this.editor.update(this.viewModel.snapshot.sessions); }
  private openRow(row: PhoneV3Utterance): void {
    // A preview owns its focus, leaving the list's cross-page selection untouched.
    const editor = new PhoneV3AnnotationEditor();
    editor.open(this.editor.batch ? [row] : this.editor.filtered, this.viewModel.snapshot.sessions);
    editor.focus(row);
    this.viewModel.stopPlayback(); this.onOpen(editor, this.scopeTitle);
  }
  private switchMode(done: boolean): void {
    this.editor.switchMode(done); this.selectedOnly = false;
    this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }
  private page(delta: number): void {
    if (this.selectedOnly) { this.editor.selectionPage = Math.max(0, Math.min(this.editor.selectionPages - 1, this.editor.selectionPage + delta)); }
    else { this.editor.page = Math.max(0, Math.min(this.editor.pages - 1, this.editor.page + delta)); }
    this.editor.filter(); this.scroller.scrollTo({ xOffset: 0, yOffset: 0 });
  }
  @Builder
  private segment(done: boolean) {
    Button(done ? `已标注 ${this.editor.done}` : `待标注 ${this.editor.pending}`).layoutWeight(1).constraintSize({ minHeight: 40 }).fontSize(14)
      .backgroundColor(this.editor.doneMode === done ? $r('app.color.surface_primary') : Color.Transparent)
      .fontColor(this.editor.doneMode === done ? $r('app.color.brand_primary') : $r('app.color.text_secondary'))
      .fontWeight(this.editor.doneMode === done ? FontWeight.Bold : FontWeight.Normal).borderRadius(10)
      .onClick((): void => this.switchMode(done))
      .accessibilityText(`${done ? '已标注' : '待标注'}${this.editor.doneMode === done ? '，已选中' : ''}`)
  }
  @Builder
  private row(row: PhoneV3Utterance) {
    Row({ space: 12 }) {
      if (this.editor.batch) {
        Checkbox({ name: row.utteranceId }).select(this.editor.isSelected(row.utteranceId))
          .onChange((checked: boolean): void => this.editor.choose(row, checked))
      }
      Column({ space: 6 }) {
        Text(phoneV3AbsoluteTime(row.startAt)).fontSize(12).fontColor($r('app.color.text_secondary'))
        Text(row.text || '（暂无转写）').fontSize(16).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.text_primary')).width('100%')
        Text(phoneV3AnnotationState(row).review ? '需复核' : phoneV3AnnotationState(row).result)
          .fontSize(13).fontColor($r('app.color.text_secondary')).maxLines(2)
        if (phoneV3AnnotationState(row).sync && phoneV3AnnotationState(row).sync !== '已同步') {
          Text(phoneV3AnnotationState(row).sync.includes('失败') ? '同步失败' : '待同步')
            .fontSize(12).fontColor($r('app.color.text_secondary'))
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).onClick((): void => this.openRow(row))
      SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([$r('app.color.text_secondary')])
        .onClick((): void => this.openRow(row))
    }.width('100%').padding({ top: 16, bottom: 16 })
  }
  build() {
    HdsNavDestination() {
      Column({ space: 12 }) {
        Row({ space: 4 }) {
          this.segment(false)
          this.segment(true)
        }.padding(4).width('100%').backgroundColor($r('app.color.surface_secondary')).borderRadius(12)
        Row({ space: 8 }) {
        TextInput({ text: this.query, placeholder: '搜索正文或时间' }).layoutWeight(1).onChange((value: string): void => {
          this.query = value; this.editor.query = value; this.editor.page = 0; this.editor.filter();
        })
          if (!this.editor.doneMode) {
            Button(this.editor.batch ? '取消' : '批量').buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(14)
              .onClick((): void => { this.editor.setBatch(!this.editor.batch); this.selectedOnly = false; })
          }
        }.width('100%')
        if (this.editor.batch) {
          Row() {
            Text(`已选 ${this.editor.selectedCount} · 筛选外 ${this.editor.hidden}`).fontSize(13).layoutWeight(1)
            Button(this.selectedOnly ? '筛选结果' : '已选清单').buttonStyle(ButtonStyleMode.TEXTUAL)
              .onClick((): void => { this.selectedOnly = !this.selectedOnly; })
          }.width('100%')
          Row() {
            Button('全选筛选结果（跨页）').buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(13)
              .onClick((): void => this.editor.selectFiltered())
            Button('清空').buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(13)
              .onClick((): void => this.editor.setBatch(true))
          }.width('100%')
        }
        List({ scroller: this.scroller }) {
          if ((this.selectedOnly ? this.editor.selectedPageRows : this.editor.pageRows).length === 0) {
            ListItem() {
              Column({ space: 16 }) {
                Text(this.query ? '没有符合搜索条件的片段' : this.editor.doneMode ? '还没有已标注片段' : this.editor.pending === 0 ? '本范围已全部标注' : '没有选择片段')
                  .fontSize(18).fontColor($r('app.color.text_primary'))
                if (!this.editor.doneMode && this.editor.done > 0) {
                  Button('查看已标注').onClick((): void => this.switchMode(true))
                }
              }.width('100%').padding({ top: 32, bottom: 32 })
            }
          }
          ForEach(this.selectedOnly ? this.editor.selectedPageRows : this.editor.pageRows, (row: PhoneV3Utterance) => {
            ListItem() { this.row(row) }
          }, (row: PhoneV3Utterance): string => phoneV3AnnotationKey(row, row.utteranceId, row.revision))
        }.layoutWeight(1).width('100%').divider({ strokeWidth: 0.5, color: $r('app.color.surface_secondary') })
        if ((this.selectedOnly ? this.editor.selectionPages : this.editor.pages) > 1) {
          Row() {
            Button('上一页').buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => this.page(-1))
            Text(`${(this.selectedOnly ? this.editor.selectionPage : this.editor.page) + 1} / ${this.selectedOnly ? this.editor.selectionPages : this.editor.pages}`)
              .layoutWeight(1).textAlign(TextAlign.Center).fontSize(13)
            Button('下一页').buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => this.page(1))
          }.width('100%')
        }
        if (this.editor.batch) {
          if (this.editor.selectedCount > 2000) { Text('每次最多标注 2000 条，请减少选择').fontSize(13) }
          Button(`标注所选 ${this.editor.selectedCount} 条`).constraintSize({ minHeight: 48 }).width('100%')
            .enabled(this.editor.selectedCount > 0 && this.editor.selectedCount <= 2000)
            .onClick((): void => this.onOpen(this.editor, this.scopeTitle))
        }
      }.width('100%').height('100%').padding({ left: 16, right: 16, top: 8, bottom: 16 })
    }.titleBar({ enableComponentSafeArea: true, content: { title: { mainTitle: this.scopeTitle } } })
      .titleMode(HdsNavDestinationTitleMode.MINI).backgroundColor($r('app.color.page_background'))
      .onShown((): void => this.refreshRows())
  }
}
