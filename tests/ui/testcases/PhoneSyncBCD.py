"""T1-T4, real production classes, TLS/HUKS, native RDB, AVPlayer and upload."""
import json
import os
from pathlib import Path
import subprocess
import time
from devicetest.core.test_case import TestCase
from hypium import BY, UiDriver
from hypium.advance.deveco_testing.step import Step

BUNDLE = 'AllDayRecording.huawei.com'


class PhoneSyncBCD(TestCase):
    def __init__(self, controllers):
        super().__init__(self.__class__.__name__, controllers)
        self.driver = UiDriver(self.device1)
        self.root = Path(os.environ['SYNC_BCD_ROOT'])
        self.results = {}

    def wait(self, selector, timeout=20):
        value = self.driver.wait_for_component(selector, timeout=timeout)
        assert value is not None, f'Missing isolated control: {selector}'
        return value

    def tap(self, identity):
        self.driver.touch(self.wait(BY.id(identity)))

    def evidence(self):
        for _ in range(20):
            try:
                return json.loads((self.root/'evidence.json').read_text(encoding='utf-8'))
            except (PermissionError, json.JSONDecodeError):
                time.sleep(.02)
        raise AssertionError('Receiver evidence unavailable')

    def state(self):
        destination = self.root/'phone-state.json'
        completed = subprocess.run(['hdc', '-t', '3DK0225528040628', 'file', 'recv',
            '/data/app/el2/100/base/AllDayRecording.huawei.com/haps/phone/cache/sync-bcd-state.json', str(destination)],
            capture_output=True, text=True)
        assert completed.returncode == 0, 'Native state export failed'
        try:
            return json.loads(destination.read_text(encoding='utf-8'))
        except json.JSONDecodeError:
            time.sleep(.1)
            return self.state()

    def until(self, predicate, timeout=45):
        deadline = time.monotonic()+timeout
        while True:
            value = predicate()
            if value:
                return value
            assert time.monotonic() < deadline, 'Business condition did not converge'
            time.sleep(.25)

    def fault(self, mode):
        (self.root/'fault.json').write_text(json.dumps({'mode':mode}), encoding='utf-8')

    def play(self, index=0):
        before = len(self.state()['plays'])
        self.tap(f'bcd-play-{index}')
        state = self.until(lambda: (s if len(s['plays']) > before else None) if (s := self.state()) else None)
        assert state['plays'][-1]['worker'] != state['plays'][-1]['main'], 'Cache IO did not run off the UI thread'
        self.until(lambda: any(t['played'] for t in self.state()['tasks']), 15)
        return state['plays'][-1]

    def restart(self):
        self.driver.stop_app(BUNDLE)
        self.driver.start_app(BUNDLE, 'EntryAbility')
        self.wait(BY.text('隔离生产链路已准备'), 45)

    def setup(self):
        self.fault('none')
        self.driver.stop_app(BUNDLE)
        self.driver.start_app(BUNDLE, 'EntryAbility')
        self.wait(BY.text('隔离 HUKS 公钥已准备'))

    def process(self):
        Step('T1 冷缓存、重复、切页、重启、电脑命中和离线播放')
        self.tap('phase2-prepare')
        self.wait(BY.text('隔离生产链路已准备'), 45)
        self.wait(BY.text('审核样本 3'))
        self.tap('bcd-pause')
        self.until(lambda: self.state()['durable'] == 0)
        cold = self.play()
        audio_before = len(self.evidence()['audio'])
        hits = [self.play(), self.play()]
        assert len(self.evidence()['audio']) == audio_before
        self.tap('bcd-open-voice')
        self.wait(BY.text('离线试听依据本机已知证据；审核提交仍需电脑确认'))
        self.driver.press_back()
        # Page prefetch may prepare other samples. Count only the current key.
        current_key = cold['key']
        count = lambda: sum(a['key'] == current_key for a in self.evidence()['audio'])
        original_count = count()
        hits.append(self.play())
        self.restart()
        hits.append(self.play())
        assert count() == original_count, 'Page/restart repeated an audio request'
        self.tap('bcd-clear')
        self.wait(BY.text('合成试听缓存已清理'))
        server_hit = self.play()
        assert self.evidence()['audio'][-1]['cache_hit'] is True
        self.fault('offline')
        hits.append(self.play())
        self.results['T1'] = {'passed':True,'cold':cold,'phone_hits':hits,'server_hit':server_hit}

        Step('T2 服务端合法更正自动到达，旧已听资格失效；中断和快速切换')
        old = self.state()['tasks']
        self.fault('change-evidence')
        self.tap('bcd-prefetch')
        self.tap('bcd-resume')
        self.until(lambda: self.evidence().get('change-evidence'), 45)
        self.until(lambda: self.state()['tasks'] != old, 45)
        assert not any(t['played'] for t in self.state()['tasks'])
        self.tap('bcd-clear')
        self.wait(BY.text('合成试听缓存已清理'))
        self.fault('audio-interrupt-once')
        before = len(self.state()['plays'])
        self.tap('bcd-play-0')
        self.until(lambda: self.state()['audioError'] and self.state()['audioLoading'] != '正在加载')
        assert len(self.state()['plays']) == before
        assert not any(t['played'] for t in self.state()['tasks'])
        self.fault('none')
        self.play()
        self.tap('bcd-clear')
        self.wait(BY.text('合成试听缓存已清理'))
        self.fault('slow-audio')
        before = len(self.state()['plays'])
        self.tap('bcd-play-0')
        self.tap('bcd-play-1')
        self.until(lambda: len(self.state()['plays']) > before)
        state = self.state()
        assert state['plays'][-1]['key'] == state['tasks'][1]['content']
        assert not state['tasks'][0]['played']
        self.fault('none')
        self.results['T2'] = {'passed':True,'stale_playback_rejected':True,'partial_not_played':True}

        Step('T3 真实限速上传中试听、预取、原生保存与回执、滚动导航')
        self.tap('bcd-clear')
        self.wait(BY.text('合成试听缓存已清理'))
        self.tap('bcd-backup')
        self.until(lambda: self.evidence()['upload_bytes'] > 0 and not self.evidence()['upload_complete'])
        self.tap('bcd-prefetch')
        during = self.play()
        self.tap('phase2-open')
        self.driver.touch(self.wait(BY.text('修改标注')))
        self.tap('annotation-setting-声音类型')
        self.driver.touch(self.wait(BY.text('非人声／噪声')))
        started = time.time()
        self.tap('annotation-save')
        self.wait(BY.text('已保存 · 待同步'), 8)
        visible = time.time()
        self.driver.press_back()
        self.until(lambda: self.evidence()['receipts'] and self.state()['durable'] == 0)
        receipt = self.evidence()['receipts'][-1]
        assert not receipt['upload_complete'] and not self.evidence()['upload_complete']
        next_key = self.state()['tasks'][1]['content']
        before = sum(a['key'] == next_key for a in self.evidence()['audio'])
        next_play = self.play(1)
        assert sum(a['key'] == next_key for a in self.evidence()['audio']) == before
        self.driver.swipe('UP', area=BY.id('phase2-scroll'))
        self.driver.swipe('DOWN', area=BY.id('phase2-scroll'))
        self.until(lambda: self.evidence()['upload_complete'], 180)
        self.results['T3'] = {'passed':True,'during_upload':during,'next_hit':next_play,
            'save_visible_proxy_ms':(visible-started)*1000,'receipt_before_upload_complete':True}

        Step('T4 离线三次保存和重启，500 后自动收敛，电脑新结果自动出现')
        self.fault('offline')
        self.tap('phase2-batch')
        self.wait(BY.text('离线三次本地提交完成'))
        assert self.state()['durable'] == 3
        self.restart()
        assert self.state()['durable'] == 3
        self.fault('500-once')
        self.until(lambda: self.evidence().get('injected_500_at'), 90)
        self.until(lambda: self.state()['durable'] == 0, 90)
        self.wait(BY.text('待同步 0'))
        count = len(self.state()['tasks'])
        self.fault('new-result')
        self.until(lambda: self.evidence().get('new-result'), 150)
        self.until(lambda: len(self.state()['tasks']) > count, 45)
        self.results['T4'] = {'passed':True,'offline_count':3,'automatic_remote_result':True,'recoverable_500':True}
        self.results['final_state'] = self.state()
        (self.root/'native-results.json').write_text(json.dumps(self.results,indent=2),encoding='utf-8')

    def teardown(self):
        (self.root/'native-partial-results.json').write_text(json.dumps(self.results,indent=2),encoding='utf-8')
        self.fault('none')
