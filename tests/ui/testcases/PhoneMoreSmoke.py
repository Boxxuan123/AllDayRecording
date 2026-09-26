"""最小手机 UI 冒烟测试：启动应用，进入“更多”，验证页面内容。"""

from devicetest.core.test_case import TestCase
from hypium import BY, UiDriver
from hypium.advance.deveco_testing.step import Step


BUNDLE_NAME = "AllDayRecording.huawei.com"


class PhoneMoreSmoke(TestCase):
    def __init__(self, controllers):
        super().__init__(self.__class__.__name__, controllers)
        self.driver = UiDriver(self.device1)

    def setup(self):
        Step("启动全天录音手机应用")
        self.driver.stop_app(BUNDLE_NAME)
        self.driver.start_app(BUNDLE_NAME, "EntryAbility")

    def process(self):
        Step("等待首页，查找“更多”页签")
        more_tab = self.driver.wait_for_component(BY.text("更多"), timeout=15)
        assert more_tab is not None, "首页未找到“更多”页签"

        Step("点击“更多”页签")
        self.driver.touch(more_tab)

        Step("验证“更多”页面中的“设备与数据”分区")
        section = self.driver.wait_for_component(BY.text("设备与数据"), timeout=10)
        assert section is not None, "点击后未看到“设备与数据”分区"

    def teardown(self):
        Step("结束测试，停止应用")
        self.driver.stop_app(BUNDLE_NAME)
