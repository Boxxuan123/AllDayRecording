import json,math,wave,io,base64,pathlib
root=pathlib.Path(__file__).resolve().parents[3]
out=root/'phone/src/main/resources/rawfile/voice-review-fixture.json'
id=lambda n:str(n).zfill(26)
time='2026-09-25T00:00:00Z'
changes=[dict(sequence=1,resource_type='recording_session',resource_id=id(9000),revision=1,operation='upsert',resource=dict(session_id=id(9000),session_key='isolated-voice-review',captured_start=time))]
for n in range(1,82):
 r=dict(utterance_id=id(n),session_id=id(9000),speaker_track_id=None,speaker_label='未知声音',original_speaker_track_id=None,original_speaker_label=None,identity='unknown',original_identity='unknown',identity_evidence={},start_ms=n*1000,end_ms=n*1000+900,start_at=time,end_at='2026-09-25T00:00:01Z',text=f'合成原句 {n}：明天上午一起核对安排。',original_text=f'合成原句 {n}：明天上午一起核对安排。',revision=1,status='active',evidence={})
 changes.append(dict(sequence=n+1,resource_type='utterance',resource_id=id(n),revision=1,operation='upsert',resource=r))
def candidate(key,nums,audio=True):
 return dict(prototype_id=key,session_id=id(9000),speaker_track_id='synthetic-track',person_name='合成人物甲',review_status='pending',review_key=key,audition_key=key,audio_available=audio,audio_unavailable_reason='合成样本音频不可用；仍可撤回授权',representative_clips=[dict(media_id='synthetic',start_ms=n*1000,end_ms=n*1000+500) for n in nums],evidence_utterances=[dict(utterance_id=id(n),revision=1,session_id=id(9000),utterance_start_ms=n*1000,utterance_end_ms=n*1000+900,window_index=i,media_id='synthetic',clip_start_ms=n*1000,clip_end_ms=n*1000+500,session_start_ms=n*1000,session_end_ms=n*1000+500) for i,n in enumerate(nums)])
def review(key,mode,cs):
 return dict(review_id=key,kind='voice_identity',priority='normal',source_id=id(7000),source_revision=None,session_id=id(9000),person_id=id(8000),title='合成声音审核',summary='',reason='voice_identity_requires_confirmation',evidence_count=len(cs),created_at=time,updated_at=time,context=dict(voice_mode=mode,review_lane='history' if mode=='accepted_grant' else 'primary',voice_candidates=cs))
reviews=[review('known','known_person',[candidate('a',[1,2,3,4,5]),candidate('b',[10,11,12,13,14])]),review('unknown','speaker_discovery',[candidate('c',[6,7,8])]),review('history','accepted_grant',[candidate('h',[9],False)])]
buf=io.BytesIO()
with wave.open(buf,'wb') as wav:
 wav.setparams((1,2,16000,0,'NONE','not compressed'))
 wav.writeframes(b''.join(int(700*math.sin(2*math.pi*440*i/16000)).to_bytes(2,'little',signed=True) for i in range(40000)))
fixture=dict(changes=changes,reviews=reviews,people=[dict(person_id=id(8000),display_name='合成人物甲'),dict(person_id=id(8001),display_name='合成人物乙')],audio=base64.urlsafe_b64encode(buf.getvalue()).decode().rstrip('='))
out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps(fixture,ensure_ascii=False),encoding='utf-8')
