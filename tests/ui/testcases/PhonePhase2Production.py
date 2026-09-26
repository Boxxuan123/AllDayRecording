"""Real production backup/authentication + automatic outbox, isolated PHONE assembly."""
import json
import os
import pathlib
import time
import subprocess
from devicetest.core.test_case import TestCase
from hypium import BY, UiDriver
from hypium.advance.deveco_testing.step import Step

BUNDLE = 'AllDayRecording.huawei.com'

class PhonePhase2Production(TestCase):
    def __init__(self, controllers):
        super().__init__(self.__class__.__name__, controllers)
        self.driver = UiDriver(self.device1)

    def wait(self, selector, timeout=15):
        result = self.driver.wait_for_component(selector, timeout=timeout)
        assert result is not None, f'Missing isolated control: {selector}'
        return result

    def tap(self, identity):
        self.driver.touch(self.wait(BY.id(identity)))

    def evidence(self):
        deadline=time.monotonic()+2
        while True:
            try:
                return json.loads(pathlib.Path(os.environ['SYNC_PHASE2A_EVIDENCE']).read_text())
            except PermissionError:
                # Windows can briefly deny an open while the writer atomically replaces it.
                if time.monotonic()>=deadline:
                    raise
                time.sleep(.01)

    def setup(self):
        self.driver.stop_app(BUNDLE)
        self.driver.start_app(BUNDLE, 'EntryAbility')
        self.wait(BY.text('隔离 HUKS 公钥已准备'))

    def export(self, name):
        target=pathlib.Path('../../outputs/sync-phase2a-closeout-private')/name
        result=subprocess.run(['hdc','-t','3DK0225528040628','file','recv',
            '/data/app/el2/100/base/AllDayRecording.huawei.com/haps/phone/cache/'+name,str(target)],capture_output=True,text=True)
        assert result.returncode==0 and target.exists(), 'isolated evidence export failed'
        return json.loads(target.read_text(encoding='utf-8'))

    def fault(self, mode):
        root=pathlib.Path(os.environ['SYNC_PHASE2A_EVIDENCE']).parent
        (root/'fault.json').write_text(json.dumps({'mode':mode}))

    def converge(self, ids, timeout=100):
        deadline=time.monotonic()+timeout
        while not set(ids).issubset({r['operation_id'] for r in self.evidence()['receipts'] if r['status']=='applied'}):
            assert time.monotonic()<deadline, 'durable operations did not converge automatically'
            time.sleep(.2)
        self.wait(BY.text('待同步 0'),30)
        self.wait(BY.text('原生持久化待同步 0'),30)

    def process(self):
        Step('独立原生 RDB 10→11，启动正式备份和轻量通道')
        self.tap('phase2-prepare')
        self.wait(BY.text('原生 RDB 10→11 通过'), 20)
        self.wait(BY.text('隔离生产链路已准备'), 40)
        deadline=time.monotonic()+30
        while True:
            before=self.evidence()
            if before['upload_bytes']>0 and not before['upload_complete']:
                break
            assert time.monotonic()<deadline, 'Production upload did not start'
            time.sleep(.1)
        previous={r['operation_id'] for r in before['receipts']}
        Step('真实生产上传未结束时，通过生产标注页保存声音类型')
        self.tap('phase2-open')
        self.driver.touch(self.wait(BY.text('修改标注')))
        self.tap('annotation-setting-声音类型')
        self.driver.touch(self.wait(BY.text('非人声／噪声')))
        save_started_at=time.time()
        self.tap('annotation-save')
        self.wait(BY.text('已保存 · 待同步'), 8)
        visible_saved_at=time.time()
        self.driver.press_back()
        deadline=time.monotonic()+30
        while True:
            saved=self.evidence()
            applied=[r for r in saved['receipts'] if r['operation_id'] not in previous and r['status']=='applied']
            if applied:
                break
            assert time.monotonic()<deadline, 'Automatic metadata receipt missing'
            time.sleep(.1)
        assert not applied[0]['upload_complete'] and applied[0]['upload_bytes']>0
        self.wait(BY.text('待同步 0'), 20)
        self.wait(BY.text('原生持久化待同步 0'), 20)
        summary_state=self.export('sync-phase2a-state.json')
        assert summary_state['times'] and summary_state['times'][0]['committed']/1000 < applied[0]['at']
        Step('实际切页返回、播放本地音频、控件范围内滚动')
        self.tap('phase2-play')
        self.wait(BY.text('播放完成'), 10)
        for _ in range(3):
            self.driver.swipe('UP', area=BY.id('phase2-scroll'))
        self.wait(BY.id('phase2-scroll-end'))
        after=self.evidence()
        assert after['upload_bytes']>before['upload_bytes'] and not after['upload_complete']
        summary={'before':before,'receipt':applied[0],'after':after,
                 'native_state_after_receipt':summary_state,
                 'driver_save_started_at':save_started_at,'driver_visible_saved_at':visible_saved_at,
                 'driver_interaction_finished_at':time.time()}
        Step('继续等待正式分片和 manifest 完成确认')
        deadline=time.monotonic()+180
        while not self.evidence()['upload_complete']:
            assert time.monotonic()<deadline, 'Manifest never completed'
            time.sleep(.5)
        summary['completed']=self.evidence()
        pathlib.Path('../../outputs/sync-phase2a-production-evidence.json').write_text(json.dumps(summary,indent=2))
        for _ in range(3):
            self.driver.swipe('DOWN', area=BY.id('phase2-scroll'))
        Step('真实 TLS 接收端断开，三次本地提交、停止重启、恢复后自动收敛')
        self.fault('offline')
        self.tap('phase2-batch')
        self.wait(BY.text('离线三次本地提交完成'))
        queued=self.export('sync-phase2a-queue.json')
        ids=[op['operation_id'] for op in queued]
        assert len(ids)==3 and len(set(ids))==3
        self.driver.stop_app(BUNDLE)
        self.driver.start_app(BUNDLE,'EntryAbility')
        self.wait(BY.text('隔离生产链路已准备'),30)
        self.wait(BY.text('原生持久化待同步 3'),20)
        self.fault('')
        self.converge(ids)
        summary['offline_restart']={'operation_ids':ids,'queue':queued,'state':self.export('sync-phase2a-state.json')}
        Step('接收端已提交但响应丢失，同一操作 ID 自动确认')
        self.fault('drop-once')
        self.tap('phase2-batch')
        self.wait(BY.text('离线三次本地提交完成'))
        dropped=self.export('sync-phase2a-queue.json')
        self.converge([op['operation_id'] for op in dropped])
        assert 'dropped_response_at' in self.evidence()
        summary['lost_response']=self.evidence()
        Step('原生数据库：最后增量无后续网络、旧快照和离开重进交错')
        self.tap('phase2-refresh')
        self.wait(BY.text('原生刷新交错通过'),60)
        summary['native_refresh']='passed; controlled scheduling, real native database and ViewModel'
        pathlib.Path('../../outputs/sync-phase2a-closeout-native-evidence.json').write_text(json.dumps(summary,indent=2))
        self.tap('phase2-clean-key')
        self.wait(BY.text('隔离测试密钥已清理'))

    def teardown(self):
        self.driver.stop_app(BUNDLE)
