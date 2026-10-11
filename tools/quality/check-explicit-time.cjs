const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {root}=require('./phone-sqlite-harness.cjs');
const {parseExplicitTime}=require(path.join(root,'domain/PhoneExplicitTime.ets'));
const {explicitChatTime}=require(path.join(root,'domain/PhoneChatFollowup.ets'));
const fixture=JSON.parse(fs.readFileSync(path.join(process.env.CHAT_PHONE_ASR_ROOT,'contracts/v3/fixtures/explicit-times.json'),'utf8'));
for(const v of fixture.valid)assert.ok(Number.isFinite(parseExplicitTime(v)),v);
for(const v of fixture.invalid)assert.throws(()=>parseExplicitTime(v),undefined,v);
assert.throws(()=>explicitChatTime('2030-02-31T09:00+08:00'));
console.log('PASS shared actual-calendar/leap-year/clock/offset cases on Phone');
