"""Read-only production phone UI acceptance for long recording pages."""

import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import time

from devicetest.core.test_case import TestCase
from hypium import BY, UiDriver
from hypium.advance.deveco_testing.step import Step


BUNDLE = "AllDayRecording.huawei.com"
HDC = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "DevEco Testing/app/resources/bin/hdc.exe"
TARGET = os.environ.get("PAGE_ACCEPTANCE_TARGET", "3DK0225528040628")
LONG_COUNT = int(os.environ.get("PAGE_ACCEPTANCE_LONG_COUNT", "1673"))
PAGE_BOUNDARY_MS = int(os.environ.get("PAGE_ACCEPTANCE_PAGE_BOUNDARY_MS", "217220"))
RESULT_DIR = Path(os.environ.get("PAGE_ACCEPTANCE_OUTPUT", "../../outputs/page-loading-phone-acceptance-20260928"))


class PhonePageLoadingAcceptance(TestCase):
    def __init__(self, controllers):
        super().__init__(self.__class__.__name__, controllers)
        self.driver = UiDriver(self.device1)
        self.results = {"target": TARGET, "long_session_utterances": LONG_COUNT}

    def wait(self, text, timeout=15):
        component = self.driver.wait_for_component(BY.text(text), timeout=timeout)
        assert component is not None, f"Missing UI text: {text}"
        return component

    def layout(self):
        dump = subprocess.run([str(HDC), "-t", TARGET, "shell", "uitest dumpLayout"],
                              capture_output=True, text=True, check=True)
        match = re.search(r"DumpLayout saved to:(\S+)", dump.stdout)
        assert match is not None, "Device did not save UI layout"
        RESULT_DIR.mkdir(parents=True, exist_ok=True)
        local = RESULT_DIR / "hypium-layout.json"
        subprocess.run([str(HDC), "-t", TARGET, "file", "recv", match.group(1), str(local)],
                       capture_output=True, text=True, check=True)
        return json.loads(local.read_text(encoding="utf-8"))

    @staticmethod
    def visible_texts(layout):
        values = []
        def visit(node):
            attrs = node.get("attributes", {})
            text = attrs.get("text", "")
            if text:
                values.append(text)
            for child in node.get("children", []):
                visit(child)
        visit(layout)
        return values

    @staticmethod
    def latest_visible_offset_ms(texts):
        offsets = []
        for text in texts:
            match = re.search(r" · (\d+):(\d{2})$", text)
            if match:
                offsets.append((int(match.group(1)) * 60 + int(match.group(2))) * 1000)
        return max(offsets, default=0)

    def open_long_session(self):
        self.driver.touch((430, 2575))
        self.wait(f"已生成 {LONG_COUNT} 条转写", 20)
        started = time.monotonic()
        self.driver.touch((530, 2350))
        self.wait("转写时间线", 20)
        return (time.monotonic() - started) * 1000

    def setup(self):
        Step("启动已安装的正式手机应用")
        self.driver.stop_app(BUNDLE)
        self.driver.start_app(BUNDLE, "EntryAbility")
        self.wait("最近录音", 30)

    def process(self):
        Step("进入 1673 条转写的长录音详情")
        self.results["open_proxy_ms"] = self.open_long_session()
        first = self.visible_texts(self.layout())
        first_rows = first.count("试听这句")
        assert 1 <= first_rows < 20, f"Initial page mounted {first_rows} transcript rows"
        self.results["initial_mounted_rows"] = first_rows
        first_time_index = next(index for index, text in enumerate(first)
                                if re.search(r" · 00:00$", text))
        search_phrase = "".join(first[first_time_index + 1].split())[:6]
        assert len(search_phrase) >= 3, "Long-session first transcript cannot drive local search"

        Step("连续滚动并确认可视区行被替换")
        for _ in range(5):
            self.driver.swipe("UP", distance=60, start_point=(0.9, 0.8), swipe_time=0.25)
        scrolled = self.visible_texts(self.layout())
        scrolled_rows = scrolled.count("试听这句")
        assert 1 <= scrolled_rows < 20, f"Scrolled page mounted {scrolled_rows} transcript rows"
        assert first != scrolled, "Scrolling did not change visible transcript content"
        self.results["scrolled_mounted_rows"] = scrolled_rows

        Step("滚过首批 50 条边界，验证后续转写可见")
        offset = self.latest_visible_offset_ms(scrolled)
        extra_swipes = 0
        while offset < PAGE_BOUNDARY_MS and extra_swipes < 110:
            self.driver.swipe("UP", distance=60, start_point=(0.9, 0.8), swipe_time=0.2)
            extra_swipes += 1
            if extra_swipes % 5 == 0:
                visible = self.visible_texts(self.layout())
                offset = self.latest_visible_offset_ms(visible)
                assert 1 <= visible.count("试听这句") < 20
        assert offset >= PAGE_BOUNDARY_MS, f"Did not cross initial page boundary: {offset} ms"
        self.results["page_boundary_visible_offset_ms"] = offset
        self.results["page_boundary_extra_swipes"] = extra_swipes

        Step("缓存超过 30 秒后连续重进长录音")
        self.driver.press_back()
        self.wait(f"已生成 {LONG_COUNT} 条转写", 15)
        Step("用转写正文搜索本地录音")
        search = self.driver.wait_for_component(BY.hint("搜索日期、转写、人物或 Session ID"), timeout=10)
        assert search is not None
        self.driver.input_text(search, search_phrase)
        time.sleep(0.7)
        assert f"已生成 {LONG_COUNT} 条转写" in self.visible_texts(self.layout()), \
            "Full transcript search did not find the long session"
        self.results["transcript_search_found_session"] = True
        self.driver.clear_text(search)
        self.driver.press_back()
        self.wait(f"已生成 {LONG_COUNT} 条转写", 15)
        time.sleep(31)
        reopen_times = []
        for index in range(10):
            reopen_times.append(self.open_long_session_from_list())
            if index < 9:
                self.driver.press_back()
                self.wait(f"已生成 {LONG_COUNT} 条转写", 15)
        self.results["reopen_proxy_ms"] = reopen_times
        self.results["reopen_proxy_p50_ms"] = statistics.median(reopen_times)
        self.results["reopen_proxy_p95_ms"] = sorted(reopen_times)[9]
        self.results["reopen_mounted_rows"] = self.visible_texts(self.layout()).count("试听这句")
        assert 1 <= self.results["reopen_mounted_rows"] < 20

        Step("本地播放期间保持时间线可用")
        self.driver.touch((650, 1360))
        self.wait("正在播放", 15)
        playing_rows = []
        for _ in range(3):
            playing_rows.append(self.visible_texts(self.layout()).count("试听这句"))
            time.sleep(0.5)
        self.results["playing_mounted_rows"] = playing_rows
        assert all(1 <= count < 20 for count in playing_rows)
        time.sleep(1)
        self.driver.touch((650, 1360))
        self.wait("已暂停", 15)
        (RESULT_DIR / "hypium-results.json").write_text(
            json.dumps(self.results, ensure_ascii=False, indent=2), encoding="utf-8")

    def open_long_session_from_list(self):
        started = time.monotonic()
        self.driver.touch((530, 2350))
        self.wait("转写时间线", 20)
        return (time.monotonic() - started) * 1000

    def teardown(self):
        self.driver.stop_app(BUNDLE)
