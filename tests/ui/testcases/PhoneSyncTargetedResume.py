"""Continue the same LAN upload if the original UI observation budget expired.
Does not reinitialize the synthetic database, cache, or upload.
"""
import json
from PhoneSyncBCD import PhoneSyncBCD
from hypium import BY


class PhoneSyncTargetedResume(PhoneSyncBCD):
    def setup(self):
        self.fault('none')
        self.driver.start_app('AllDayRecording.huawei.com', 'EntryAbility')
        self.wait(BY.text('隔离生产链路已准备'), 30)

    def process(self):
        before = self.evidence()
        assert before.get('peer_loopback') is False
        assert before['receipts'] and before['receipts'][0]['upload_complete'] is False
        self.until(lambda: self.evidence()['upload_complete'], 600)
        count = len(self.evidence()['receipts'])
        self.fault('offline')
        self.tap('phase2-batch')
        self.wait(BY.text('离线三次本地提交完成'))
        assert self.state()['durable'] == 3
        failed = self.until(lambda: (s if s.get('error') else None) if (s := self.state()) else None, 60)
        assert '12 秒' not in failed['error']
        self.fault('none')
        self.until(lambda: self.state()['durable'] == 0, 90)
        receipts = self.evidence()['receipts']
        assert len({r['operation_id'] for r in receipts}) == count + 3
        self.results = {'passed': True, 'lan_non_loopback': True, 'upload_complete': True,
                        'receipt_before_upload_complete': True, 'offline_error_observed': True,
                        'not_discovery_timeout': True, 'new_unique_receipts': 3,
                        'final_pending': self.state()['durable']}
        (self.root/'native-continuation.json').write_text(json.dumps(self.results, indent=2), encoding='utf-8')

    def teardown(self):
        self.fault('none')
