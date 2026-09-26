"""Native UI + real synthetic TLS bytes; no production receiver or real audio."""
import json
import os
import pathlib
import ssl
import time
import urllib.request
from hypium import BY
from hypium.advance.deveco_testing.step import Step
from PhoneOfflineAnnotation import PhoneOfflineAnnotation


class PhoneSyncInteraction(PhoneOfflineAnnotation):
    def progress(self):
        context = ssl.create_default_context(cafile=os.environ['SYNC_PHASE1_TEST_CA'])
        with urllib.request.urlopen('https://127.0.0.1:19099/progress', context=context, timeout=3) as response:
            return json.load(response)

    def process(self):
        Step('启动独立测试接收端上的真实慢 TLS 传输')
        self.tap('phase1-transfer-start')
        deadline = time.monotonic() + 10
        before = self.progress()
        while before['received'] <= 0 or before['ended']:
            assert time.monotonic() < deadline, 'No real transfer reached the test receiver'
            time.sleep(0.1)
            before = self.progress()
        self.wait(BY.text('合成传输进行中'))

        Step('传输仍在进行时进入生产标注页面并提交本地标注')
        self.choose_person('one')
        self.tap('annotation-save')
        self.wait(BY.text('已保存 · 待同步'), timeout=8)
        saved = self.progress()
        assert before['received'] < saved['received'] < saved['total'] and not saved['ended']
        self.driver.press_back()
        self.tap('phase1-read')
        self.wait(BY.text('持久化操作 1'))

        Step('传输仍在进行时播放本地合成音频，等待原生播放器完成')
        self.tap('phase1-play')
        self.wait(BY.text('播放完成'), timeout=10)
        played = self.progress()
        assert saved['received'] < played['received'] < played['total'] and not played['ended']
        self.wait(BY.text('合成传输进行中'))
        output = pathlib.Path('../../outputs/sync-phase1-interaction-evidence.json')
        output.write_text(json.dumps({'before': before, 'saved': saved, 'played': played}, indent=2))
