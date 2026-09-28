"""Read-only HarmonyOS purity-review smoke test using hdc and uitest.

Requires a connected phone with the updated HAP and a running PC receiver.
It opens the review UI, plays target/context audio, checks skip and history,
and never submits a speaker or purity verdict.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
import subprocess
import tempfile
import time
from pathlib import Path

BUNDLE = "AllDayRecording.huawei.com"
DEVICE_LAYOUT = "/data/local/tmp/purity-audit-layout.json"


def run(command: list[str], *, timeout: int = 30) -> str:
    completed = subprocess.run(command, capture_output=True, text=True,
                               timeout=timeout, check=False)
    if completed.returncode:
        raise RuntimeError(f"Command failed ({completed.returncode}): {' '.join(command[:4])}\n{completed.stderr}")
    return completed.stdout


def hdc(hdc_path: str, device: str, *args: str) -> str:
    return run([hdc_path, "-t", device, *args])


def database_counts(path: Path) -> tuple[int, int]:
    connection = sqlite3.connect(f"file:{path.as_posix()}?mode=ro", uri=True)
    try:
        tasks = connection.execute("SELECT COUNT(*) FROM speaker_profile_purity_tasks").fetchone()[0]
        reviews = connection.execute("SELECT COUNT(*) FROM speaker_profile_purity_reviews").fetchone()[0]
        return tasks, reviews
    finally:
        connection.close()


def nodes(value: dict):
    yield value.get("attributes", {})
    for child in value.get("children", []):
        yield from nodes(child)


def layout(hdc_path: str, device: str, target: Path) -> list[dict]:
    hdc(hdc_path, device, "shell", "uitest", "dumpLayout", "-p", DEVICE_LAYOUT)
    hdc(hdc_path, device, "file", "recv", DEVICE_LAYOUT, str(target))
    return list(nodes(json.loads(target.read_text(encoding="utf-8"))))


def find(items: list[dict], label: str, *, exact: bool = False) -> dict | None:
    for item in items:
        value = item.get("text", "")
        if (value == label if exact else label in value):
            return item
    return None


def wait_for(hdc_path: str, device: str, target: Path, label: str,
             *, exact: bool = False, seconds: float = 12) -> tuple[list[dict], dict]:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        items = layout(hdc_path, device, target)
        item = find(items, label, exact=exact)
        if item is not None:
            return items, item
        time.sleep(0.5)
    raise AssertionError(f"UI text did not appear: {label}")


def click(hdc_path: str, device: str, item: dict) -> None:
    bounds = item.get("bounds", "")
    match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
    if match is None:
        raise AssertionError(f"Invalid UI bounds: {bounds}")
    left, top, right, bottom = map(int, match.groups())
    hdc(hdc_path, device, "shell", "uitest", "uiInput", "click",
        str((left + right) // 2), str((top + bottom) // 2))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hdc", required=True, help="path to hdc executable")
    parser.add_argument("--device", help="hdc device ID; auto-select if only one is connected")
    parser.add_argument("--pc-db", required=True, type=Path, help="PC state/v3/core.sqlite3")
    args = parser.parse_args()
    device = args.device
    if not device:
        devices = [line.strip() for line in run([args.hdc, "list", "targets"]).splitlines()
                   if line.strip() and line.strip() != "[Empty]"]
        if len(devices) != 1:
            raise RuntimeError(f"Expected one connected device, found {len(devices)}")
        device = devices[0].split()[0]
    expected_tasks, starting_reviews = database_counts(args.pc_db)
    if expected_tasks == 0:
        raise AssertionError("No generated purity tasks in the PC database")
    hdc(args.hdc, device, "shell", "aa", "start", "-a", "EntryAbility", "-b", BUNDLE)
    with tempfile.TemporaryDirectory(prefix="purity-device-smoke-") as directory:
        target = Path(directory) / "layout.json"
        try:
            items, _ = wait_for(args.hdc, device, target, "审核", exact=True)
            tabs = [item for item in items if item.get("text") == "审核"]
            click(args.hdc, device, tabs[-1])
            items, card = wait_for(args.hdc, device, target, "段待听")
            count_match = re.search(r"(\d+)\s*段待听", card["text"])
            if count_match is None or int(count_match.group(1)) != expected_tasks:
                raise AssertionError("Phone pending count differs from the PC audit task count")
            click(args.hdc, device, find(items, "开始审核", exact=True))
            items, _ = wait_for(args.hdc, device, target, "播放目标片段")
            for label in ("听前后文", "这段主要是谁在说话？", "稍后再看"):
                if find(items, label) is None:
                    raise AssertionError(f"Missing purity review control: {label}")
            visible = "\n".join(item.get("text", "") for item in items)
            if any(value in visible for value in ("高风险", "最像本人", "cosine", "P0-special")):
                raise AssertionError("Pre-verdict risk reason leaked into the phone UI")
            click(args.hdc, device, find(items, "播放目标片段"))
            items, _ = wait_for(args.hdc, device, target, "重播目标片段", seconds=20)
            click(args.hdc, device, find(items, "听前后文", exact=True))
            items, _ = wait_for(args.hdc, device, target, "上下文播放中", seconds=20)
            click(args.hdc, device, find(items, "稍后再看", exact=True))
            wait_for(args.hdc, device, target, "声纹纯度审核")
            if database_counts(args.pc_db) != (expected_tasks, starting_reviews):
                raise AssertionError("Read-only device test changed the audit database")
            hdc(args.hdc, device, "shell", "uitest", "uiInput", "keyEvent", "Back")
            items, history_button = wait_for(args.hdc, device, target, "纯度已审核")
            click(args.hdc, device, history_button)
            wait_for(args.hdc, device, target, "暂无已审核记录")
        finally:
            hdc(args.hdc, device, "shell", "uitest", "uiInput", "keyEvent", "Back")
    if database_counts(args.pc_db) != (expected_tasks, starting_reviews):
        raise AssertionError("Audit database changed during device test")
    print(json.dumps({"status": "PASS", "device_tasks": expected_tasks,
                      "review_rows_unchanged": True,
                      "checked": ["inbox", "target_audio", "context_audio", "skip", "history"]}))


if __name__ == "__main__":
    main()
