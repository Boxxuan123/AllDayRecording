"""Remove only the isolated B/C/D HUKS key through the fixture's own UI."""
from devicetest.core.test_case import TestCase
from hypium import BY, UiDriver


class PhoneSyncBCDCleanup(TestCase):
    def __init__(self, controllers):
        super().__init__(self.__class__.__name__, controllers)
        self.driver = UiDriver(self.device1)

    def setup(self):
        self.driver.start_app('AllDayRecording.huawei.com', 'EntryAbility')

    def process(self):
        for _ in range(5):
            target = self.driver.wait_for_component(BY.id('phase2-clean-key'), timeout=1)
            if target is not None:
                self.driver.touch(target)
                break
            self.driver.swipe('UP', area=BY.id('phase2-scroll'))
        else:
            raise AssertionError('Isolated key cleanup control not found')
        assert self.driver.wait_for_component(BY.text('隔离测试密钥已清理'), timeout=20) is not None

    def teardown(self):
        self.driver.stop_app('AllDayRecording.huawei.com')
