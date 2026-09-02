import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { PhoneComputerTransferViewModel } from './PhoneComputerTransferViewModel';

@Component
export struct PhoneComputerTransferPage {
  @State private transferViewModel: PhoneComputerTransferViewModel = new PhoneComputerTransferViewModel();

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.transferViewModel.start(context);
  }

  private async chooseCa(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(context);
      const selected = await documentPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['PEM 证书 (.pem, .crt)|.pem,.crt']
      });
      if (selected.length > 0) {
        await this.transferViewModel.importCa(selected[0]);
      }
    } catch (error) {
      const value = error as Error;
      if (value.message !== undefined && value.message.length > 0) {
        this.transferViewModel.status = `选择 CA 失败：${value.message}`;
      }
    }
  }

  private async scanComputerPairingQr(): Promise<void> {
    try {
      if (!canIUse('SystemCapability.Multimedia.Scan.ScanBarcode')) {
        throw new Error('本机系统不支持二维码扫描');
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const result = await scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: false
      });
      await this.transferViewModel.pairFromQr(result.originalValue);
    } catch (error) {
      const value = error as Error;
      if (value.message !== undefined && value.message.length > 0) {
        this.transferViewModel.status = `扫描配对失败：${value.message}`;
      }
    }
  }

  @Builder
  private sectionTitle(value: string) {
    Text(value)
      .width('100%')
      .fontSize(17)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
  }

  @Builder
  private explanation(value: string) {
    Text(value)
      .width('100%')
      .fontSize(13)
      .lineHeight(19)
      .fontColor($r('app.color.text_secondary'))
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Column({ space: 10 }) {
          this.sectionTitle('1. 首次配对')

          Button(this.transferViewModel.paired ? '电脑已配对' : '扫描电脑上的配对二维码',
            { type: ButtonType.Capsule })
            .width('100%')
            .height(50)
            .enabled(!this.transferViewModel.busy && !this.transferViewModel.paired)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.brand_primary'))
            .onClick((): void => {
              this.scanComputerPairingQr();
            })

          this.explanation('首次扫描电脑接收端生成的二维码，再确认一次 Passkey。之后换 Wi-Fi、换 IP 都会自动发现并静默认证。')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(14)

        Column({ space: 10 }) {
          this.sectionTitle('手动配对备用：电脑地址')

          TextInput({
            text: this.transferViewModel.baseUrl,
            placeholder: 'https://192.168.1.20:8766'
          })
            .width('100%')
            .height(48)
            .enabled(!this.transferViewModel.busy && !this.transferViewModel.paired)
            .onChange((value: string): void => {
              this.transferViewModel.baseUrl = value;
            })

          this.explanation('只用于无法扫描二维码时的首次调试。配对完成后应用会自动发现地址，不需要再修改。')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(14)

        Column({ space: 10 }) {
          this.sectionTitle('手动配对备用：核对电脑身份')

          TextInput({
            text: this.transferViewModel.expectedFingerprint,
            placeholder: '电脑终端显示的 CA SHA-256 指纹'
          })
            .width('100%')
            .height(48)
            .enabled(!this.transferViewModel.busy && !this.transferViewModel.paired)
            .onChange((value: string): void => {
              this.transferViewModel.expectedFingerprint = value;
            })

          Button('选择电脑生成的 CA 证书', { type: ButtonType.Capsule })
            .width('100%')
            .height(46)
            .enabled(!this.transferViewModel.busy && !this.transferViewModel.paired)
            .onClick((): void => {
              this.chooseCa();
            })

          if (this.transferViewModel.importedFingerprint.length > 0) {
            Text(`已验证：${this.transferViewModel.importedFingerprint}`)
              .width('100%')
              .fontSize(12)
              .fontColor($r('app.color.brand_primary'))
          }

          this.explanation('证书必须从电脑接收端导出，并与电脑终端显示的指纹逐字一致；应用不会接受未知证书。')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(14)

        Column({ space: 10 }) {
          this.sectionTitle('手动配对备用：确认 Passkey')

          TextInput({
            text: this.transferViewModel.pairingCode,
            placeholder: '电脑终端显示的首次配对码'
          })
            .type(InputType.Password)
            .showPasswordIcon(true)
            .width('100%')
            .height(48)
            .enabled(!this.transferViewModel.busy)
            .onChange((value: string): void => {
              this.transferViewModel.pairingCode = value;
            })

          Button(this.transferViewModel.paired ? 'Passkey 已配对' : '创建并登记 Passkey',
            { type: ButtonType.Capsule })
            .width('100%')
            .height(48)
            .enabled(!this.transferViewModel.busy && !this.transferViewModel.paired)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.brand_primary'))
            .onClick((): void => {
              this.transferViewModel.pair();
            })

          Text(this.transferViewModel.passkeyCapability)
            .width('100%')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))

          Text(this.transferViewModel.deviceKeyCapability)
            .width('100%')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))

          if (this.transferViewModel.rpId.length > 0) {
            Text(`RP：${this.transferViewModel.rpId}`)
              .width('100%')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
          }

          this.explanation('Passkey 只确认首次授权；长期设备私钥保存在 HUKS，后续上传不会反复弹出认证。')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(14)

        Column({ space: 10 }) {
          this.sectionTitle('2. 上传录音')

          Text(`可上传 ${this.transferViewModel.availableSessions} 个会话，` +
            `${this.transferViewModel.availableRecordings} 个录音分片`)
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))

          if (this.transferViewModel.busy || this.transferViewModel.progressPercent > 0) {
            Progress({ value: this.transferViewModel.progressPercent, total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(8)
              .color($r('app.color.brand_primary'))
          }

          Button('上传到电脑', { type: ButtonType.Capsule })
            .width('100%')
            .height(50)
            .enabled(!this.transferViewModel.busy && this.transferViewModel.paired &&
              this.transferViewModel.availableRecordings > 0)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.brand_primary'))
            .onClick((): void => {
              this.transferViewModel.upload();
            })

          this.explanation('上传前自动发现已配对电脑，再用 HUKS 设备密钥静默认证。录音支持断点续传，手机原文件不会删除。')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(14)

        Column({ space: 10 }) {
          this.sectionTitle('3. V3 状态同步')

          Text(`本地游标 ${this.transferViewModel.syncCursor}，` +
            `待提交 ${this.transferViewModel.pendingOperations} 项`)
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))

          Text(`最近处理状态：${this.transferViewModel.cachedProcessingStatus}`)
            .width('100%')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))

          Button('同步处理状态', { type: ButtonType.Capsule })
            .width('100%')
            .height(48)
            .enabled(!this.transferViewModel.busy && this.transferViewModel.paired)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.brand_primary'))
            .onClick((): void => {
              this.transferViewModel.synchronize();
            })

          Button('从电脑重建本地投影', { type: ButtonType.Capsule })
            .width('100%')
            .height(44)
            .enabled(!this.transferViewModel.busy && this.transferViewModel.paired)
            .onClick((): void => {
              this.transferViewModel.rebuildProjection();
            })

          this.explanation('同步会在一条 HUKS 签名请求中提交 outbox 并拉取增量。离线时本地录音、上次状态和待提交项仍会保留。')
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor($r('app.color.surface_primary'))
        .borderRadius(14)

        Text(this.transferViewModel.status)
          .width('100%')
          .padding(14)
          .fontSize(14)
          .lineHeight(20)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.surface_secondary'))
          .borderRadius(12)
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 40 })
      .alignItems(HorizontalAlign.Start)
    }
    .align(Alignment.TopStart)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
