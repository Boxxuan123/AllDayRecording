import { PhoneDailyCache, PhoneDailySummary, PhoneDailyEvent, phoneDailyDisplayText } from '../domain/PhoneV3DailyModels';
import { PhoneUnifiedClaim, unifiedEvidenceForClaim } from '../domain/PhoneUnifiedReview';
import { PhoneProductEvidence, dailyProductEvidence, unifiedProductEvidence } from './PhoneProductEvidence';
export class PhoneProductHighlight {
  text: string = '';
  label: string = '模型归纳';
  evidence: Array<PhoneProductEvidence> = [];
}
export class PhoneProductDay {
  date: string = '';
  title: string = '';
  notice: string = '';
  updated: string = '';
  coverage: string = '';
  highlights: Array<PhoneProductHighlight> = [];
  timeline: Array<PhoneDailyEvent> = [];
}
export function productDay(cache: PhoneDailyCache, today: string): PhoneProductDay {
  const result = new PhoneProductDay();
  const summaries = cache.summaries.filter((s:PhoneDailySummary):boolean=>s.summary_date<=today&&s.timezone==='Asia/Singapore').slice().sort((a:PhoneDailySummary,b:PhoneDailySummary):number=>b.summary_date.localeCompare(a.summary_date));
  for (const summary of summaries) {
    const review=summary.objective.unified_review;
    const highlights: Array<PhoneProductHighlight> = [];
    const events=cache.events.filter((e:PhoneDailyEvent):boolean=>e.local_date===summary.summary_date&&e.timezone===summary.timezone&&e.derivation_status==='active'&&summary.objective.source_event_revisions[e.event_id]===e.revision);
    if (review!==undefined) {
      for (const claim of review.claims) {
        const evidence=unifiedEvidenceForClaim(review,claim).map(unifiedProductEvidence);
        if (evidence.length===0 || claim.text.trim().length===0) { continue; }
        const highlight=new PhoneProductHighlight(); highlight.text=claim.text;
        highlight.label=(claim.perspective==='observed'?'听到或看到的内容':claim.perspective==='other'?'他人的事情':claim.perspective==='self'?'与我有关的内容':'人物身份未确认')+' · 模型归纳'+(claim.certainty==='uncertain'?' · 尚不确定':''); highlight.evidence=evidence; highlights.push(highlight);
      }
    } else if (summary.derivation_status==='active'&&summary.objective.semantic_status==='complete') {
      for (const item of summary.objective.major_events??summary.objective.key_events) {
        const evidence=events.filter((e:PhoneDailyEvent):boolean=>item.event_ids.includes(e.event_id)).flatMap((e:PhoneDailyEvent):Array<PhoneProductEvidence>=>e.evidence_snapshots.map(dailyProductEvidence));
        const text=phoneDailyDisplayText(item.text??item.title??'',summary.objective.source_event_ids);
        if (evidence.length>0&&text.length>0) { const highlight=new PhoneProductHighlight(); highlight.text=text; highlight.evidence=evidence; highlights.push(highlight); }
      }
    }
    if (highlights.length===0) { continue; }
    result.date=summary.summary_date; result.title=result.date===today?'今日回顾':`${result.date} · 最近可用回顾`;
    result.highlights=highlights.slice(0,2); result.timeline=events;
    result.updated=review?.revised_at??review?.generated_at??'';
    result.coverage=review===undefined?'仅覆盖已同步录音证据':(review.coverage?.missing_sources?.length??0)>0?'部分来源未覆盖':(review.coverage?.chat_records_selected??0)>0&&(review.coverage?.recording_evidence??0)>0?'已同步聊天与录音；并非全天完整记录':(review.coverage?.recording_evidence??0)>0?'仅有已同步录音证据':(review.coverage?.chat_records_selected??0)>0?'仅有已同步聊天证据':'本次资料覆盖范围尚未确认';
    result.notice=result.date!==today?'今天尚无可用回顾，先回看最近内容':'';
    if (summary.derivation_status!=='active'||review!==undefined&&review.status!=='ready') { result.notice += (result.notice.length>0?' · ':'')+'本次归纳未更新，以下为上次保存内容'; }
    return result;
  }
  result.title='最近内容'; result.notice='今天尚无回顾，可直接回看已有记录';
  result.timeline=cache.events.filter((e:PhoneDailyEvent):boolean=>e.derivation_status==='active'&&e.evidence_snapshots.length>0).slice(-6).reverse();
  result.coverage='只显示手机已同步的内容'; return result;
}
