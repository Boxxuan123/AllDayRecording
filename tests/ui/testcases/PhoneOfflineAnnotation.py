"""Run only with sync-phase1-device isolated entry installed on the PHONE."""
from devicetest.core.test_case import TestCase
from hypium import BY, UiDriver
from hypium.advance.deveco_testing.step import Step

BUNDLE = 'AllDayRecording.huawei.com'


class PhoneOfflineAnnotation(TestCase):
    def __init__(self, controllers):
        super().__init__(self.__class__.__name__, controllers)
        self.driver = UiDriver(self.device1)

    def wait(self, selector, timeout=10):
        result = self.driver.wait_for_component(selector, timeout=timeout)
        assert result is not None, f'Missing synthetic test control: {selector}'
        return result

    def tap(self, component_id):
        self.driver.touch(self.wait(BY.id(component_id)))

    def setup(self):
        self.driver.stop_app(BUNDLE)
        self.driver.start_app(BUNDLE, 'EntryAbility')
        # This guard must fail before touching anything in a production build.
        self.wait(BY.text('隔离验收 · 接收端离线'))
        self.tap('phase1-reset')
        self.wait(BY.text('持久化操作 0'))

    def choose_person(self, row):
        self.tap(f'phase1-open-{row}')
        self.tap('annotation-setting-说话人')
        self.tap('annotation-person-' + str(8000).zfill(26))
        self.wait(BY.id('annotation-save'))

    def process(self):
        Step('接收端离线：真实生产页面保存合成人物标注')
        self.choose_person('one')
        self.tap('annotation-save')
        self.wait(BY.text('已保存 · 待同步'), timeout=8)
        self.driver.press_back()
        self.tap('phase1-read')
        self.wait(BY.text('持久化操作 1'))

        Step('结束进程后重启，从真实 RDB 读回同一条操作')
        self.driver.stop_app(BUNDLE)
        self.driver.start_app(BUNDLE, 'EntryAbility')
        self.wait(BY.text('隔离验收 · 接收端离线'))
        self.wait(BY.text('持久化操作 1'))
        self.tap('phase1-open-one')
        self.wait(BY.text('待同步'))
        self.driver.press_back()

        Step('仅在隔离 RDB 注入写入失败：不得生成第二条操作或假成功')
        self.tap('phase1-fail')
        self.wait(BY.text('隔离写入故障已启用'))
        self.choose_person('two')
        self.tap('annotation-save')
        error = self.wait(BY.id('annotation-error'))
        assert '数据库保存失败' in self.driver.get_component_property(error, 'text')
        self.driver.stop_app(BUNDLE)
        self.driver.start_app(BUNDLE, 'EntryAbility')
        self.wait(BY.text('持久化操作 1'))

    def teardown(self):
        self.driver.stop_app(BUNDLE)
