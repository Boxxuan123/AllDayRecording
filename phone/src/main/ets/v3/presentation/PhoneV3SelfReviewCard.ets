import { PhoneV3ReviewItem } from '../domain/PhoneV3Models';
import { phoneV3VoiceCandidates } from '../domain/PhoneV3ReviewModels';
import { selfReviewDetail } from '../domain/PhoneV3SelfReview';
import { PhoneV3ViewModel } from './PhoneV3ViewModel';

@Component
export struct PhoneV3SelfReviewCard {
  item: PhoneV3ReviewItem = new PhoneV3ReviewItem('', 'self_identity_review', 'normal', '', null, null, null, '', '', '', 0, '', '', '{}');
  viewModel: PhoneV3ViewModel = new PhoneV3ViewModel();
  @Prop @Watch('refreshState') stateRevision: number = 0;
  @State private played: boolean = false;
  @State private queued: boolean = false;
  @State private message: string = '';
  @State private playing: boolean = false;

  aboutToAppear(): void { this.refreshState(); }
  private refreshState(): void {
    this.played = this.viewModel.reviewSampleWasPlayed(this.item.reviewId, this.sampleId());
    this.queued = this.viewModel.reviewSubmissionState(this.item.reviewId, this.sampleId()).length > 0;
    this.message = this.viewModel.reviewSubmissionMessage(this.item.reviewId, this.sampleId());
    this.playing = this.viewModel.reviewPlaybackPrototype === this.sampleId();
  }

  private sampleId(): string { return phoneV3VoiceCandidates(this.item)[0]?.prototypeId ?? ''; }
  private pending(): boolean { return this.queued; }
  private canDecide(): boolean { return !this.queued && this.played; }
  private decide(action: string): void {
    this.viewModel.resolveReview(this.item.reviewId, action, this.sampleId(), '', (): void => this.viewModel.stopPlayback());
  }

  build() {
    Column({ space: 10 }) {
      Text('可能是本人').fontSize(18).fontWeight(FontWeight.Medium).width('100%')
      Text(`${selfReviewDetail(this.item).time} · ${selfReviewDetail(this.item).duration}`).fontSize(13).width('100%')
      Text(selfReviewDetail(this.item).text).fontSize(15).width('100%')
      Text('本人匹配较高，但有效语音不足自动确认要求').fontSize(13).width('100%')
      Text('确认仅修正身份，不会加入声纹画像').fontSize(12).fontColor($r('app.color.text_secondary')).width('100%')
      Button(this.playing ? '正在播放' : '播放音频')
        .width('100%').enabled(phoneV3VoiceCandidates(this.item)[0]?.hasAudio === true && !this.pending())
        .onClick((): void => this.viewModel.playReviewSample(this.item.reviewId, this.sampleId(), (): void => this.refreshState()))
      if (this.pending()) {
        Text(this.message).fontSize(13).width('100%')
        Button('同步审核结果').onClick((): void => this.viewModel.refreshVoiceReviews())
      } else {
        Row({ space: 8 }) {
          Button('是我').layoutWeight(1).enabled(this.canDecide()).onClick((): void => this.decide('confirm'))
          Button('不是我').layoutWeight(1).enabled(this.canDecide()).onClick((): void => this.decide('reject'))
          Button('不确定').layoutWeight(1).onClick((): void => this.decide('uncertain'))
        }.width('100%')
      }
    }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
      .backgroundColor($r('app.color.surface_primary')).borderRadius(16)
  }
}
