import { DeviceV3PersonChoice } from '../../computer/ComputerTransferProtocol';

// Shared draft-only selector. Choosing a name never creates a database person.
@Component
export struct PhoneV3PersonSelector {
  @Prop people: Array<DeviceV3PersonChoice> = [];
  @Prop selectedId: string = '';
  @State private query: string = '';
  @State private creating: boolean = false;
  @State private name: string = '';
  onSelect: (id: string, name: string) => void = (): void => {};
  onCancel: () => void = (): void => {};
  build() {
    Column({ space: 16 }) {
      Row() {
        Text(this.creating ? '新建人物' : '选择说话人').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary')).layoutWeight(1)
        Button('取消').buttonStyle(ButtonStyleMode.TEXTUAL).fontColor($r('app.color.text_secondary'))
          .onClick((): void => { if (this.creating) { this.creating = false; this.name = ''; } else { this.onCancel(); } })
      }.width('100%')
      if (this.creating) {
        TextInput({ text: this.name, placeholder: '人物姓名' }).maxLength(100).onChange((value: string): void => { this.name = value; })
        Text('保存标注时才会创建人物').fontSize(13).fontColor($r('app.color.text_secondary')).width('100%')
        Button('使用此姓名').width('100%').constraintSize({ minHeight: 48 }).enabled(this.name.trim().length > 0)
          .onClick((): void => this.onSelect('', this.name.trim()))
      } else {
        TextInput({ text: this.query, placeholder: '搜索人物' }).onChange((value: string): void => { this.query = value; })
        List() {
          ForEach(this.people.filter((p: DeviceV3PersonChoice): boolean => p.display_name.toLowerCase().includes(this.query.toLowerCase())),
            (p: DeviceV3PersonChoice) => {
              ListItem() {
                Row({ space: 12 }) {
                  Text(p.display_name).fontSize(16).layoutWeight(1).fontColor($r('app.color.text_primary'))
                  if (this.selectedId === p.person_id) { SymbolGlyph($r('sys.symbol.checkmark')).fontSize(20).fontColor([$r('app.color.brand_primary')]) }
                }.id(`annotation-person-${p.person_id}`).width('100%').constraintSize({ minHeight: 56 }).padding(16)
                  .onClick((): void => this.onSelect(p.person_id, p.display_name))
              }
            }, (p: DeviceV3PersonChoice): string => p.person_id)
          ListItem() {
            Row() {
              Text('新建人物').fontSize(16).layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14)
            }.padding(16).constraintSize({ minHeight: 60 }).width('100%').backgroundColor($r('app.color.surface_primary'))
              .onClick((): void => { this.creating = true; this.name = ''; })
          }
        }.layoutWeight(1).width('100%')
      }
    }.padding(16).width('100%').height('100%').alignItems(HorizontalAlign.Start).backgroundColor($r('app.color.page_background'))
  }
}
