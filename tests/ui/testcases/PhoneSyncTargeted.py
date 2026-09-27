"""Single targeted LAN flow; reuse production BCD fixture and driver helpers."""
import json
import time
from PhoneSyncBCD import PhoneSyncBCD
from hypium import BY
from hypium.advance.deveco_testing.step import Step


class PhoneSyncTargeted(PhoneSyncBCD):
    def process(self):
        Step('Same-window prefetch failure recovers over real Wi-Fi without UI retry')
        self.tap('phase2-prepare')
        self.wait(BY.text('隔离生产链路已准备'), 45)
        self.wait(BY.text('审核样本 3'))
        assert self.evidence().get('peer_loopback') is False, 'Business requests must use LAN, not rport'
        self.fault('audio-offline')
        self.tap('bcd-prefetch')
        self.until(lambda: self.evidence().get('audio_failures', 0) > 0)
        self.until(lambda: any('等待' in t['cacheState'] for t in self.state()['tasks']))
        self.fault('none')  # Early recovery, no further UI/network event injected.
        self.until(lambda: all('已缓存' in t['cacheState'] for t in self.state()['tasks']), 100)
        assert not any(t['played'] for t in self.state()['tasks'])
        before = len(self.evidence()['audio'])
        first = self.play()
        repeat = self.play()
        assert len(self.evidence()['audio']) == before
        self.tap('bcd-open-voice')
        self.wait(BY.text('离线试听依据本机已知证据；审核提交仍需电脑确认'))
        self.driver.press_back()
        self.play()
        self.results['prefetch_recovery'] = {'passed': True, 'lan_non_loopback': True, 'first': first, 'repeat': repeat}

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
            'save_visible_proxy_ms':(visible-started)*1000,'local_save_times':self.state()['times'],
            'receipt_before_upload_complete':True}

        Step('Same trusted LAN receiver returns; durable pending work resumes')
        self.fault('offline')
        self.tap('phase2-batch')
        self.wait(BY.text('离线三次本地提交完成'))
        assert self.state()['durable'] == 3
        self.fault('none')
        self.until(lambda: self.state()['durable'] == 0, 90)
        receipts = self.evidence()['receipts']
        assert len({r['operation_id'] for r in receipts}) == 4
        self.results['recovery'] = {'passed': True, 'unique_receipts': 4}
        self.results['final_state'] = self.state()
        (self.root/'native-results.json').write_text(json.dumps(self.results, indent=2), encoding='utf-8')
