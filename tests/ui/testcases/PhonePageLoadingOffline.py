"""Verify cached transcript, local playback and search while Wi-Fi is disabled."""

import json
import re
import time

from hypium import BY
from hypium.advance.deveco_testing.step import Step

from PhonePageLoadingAcceptance import LONG_COUNT, RESULT_DIR, PhonePageLoadingAcceptance


class PhonePageLoadingOffline(PhonePageLoadingAcceptance):
    def process(self):
        Step("Wi-Fi 关闭时进入本地长录音")
        self.results["open_proxy_ms"] = self.open_long_session()
        first = self.visible_texts(self.layout())
        rows = first.count("试听这句")
        assert 1 <= rows < 20
        self.results["initial_mounted_rows"] = rows

        Step("Wi-Fi 关闭时播放本地录音")
        self.driver.touch((650, 1360))
        self.wait("正在播放", 15)
        time.sleep(1)
        self.driver.touch((650, 1360))
        self.wait("已暂停", 15)
        self.results["local_playback_passed"] = True

        Step("Wi-Fi 关闭时搜索已缓存的转写正文")
        first_time_index = next(index for index, text in enumerate(first)
                                if re.search(r" · 00:00$", text))
        phrase = "".join(first[first_time_index + 1].split())[:6]
        assert len(phrase) >= 3
        self.driver.press_back()
        self.wait(f"已生成 {LONG_COUNT} 条转写", 15)
        search = self.driver.wait_for_component(BY.hint("搜索日期、转写、人物或 Session ID"), timeout=10)
        assert search is not None
        self.driver.input_text(search, phrase)
        time.sleep(0.7)
        assert f"已生成 {LONG_COUNT} 条转写" in self.visible_texts(self.layout())
        self.driver.clear_text(search)
        self.driver.press_back()
        self.results["offline_transcript_search_passed"] = True
        RESULT_DIR.mkdir(parents=True, exist_ok=True)
        (RESULT_DIR / "hypium-offline-results.json").write_text(
            json.dumps(self.results, ensure_ascii=False, indent=2), encoding="utf-8")
