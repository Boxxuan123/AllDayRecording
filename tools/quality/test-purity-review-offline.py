"""Verify cached purity audio on the phone while the PC receiver is stopped.

The receiver is restarted in ``finally`` even if the device smoke test fails.
The smoke test only plays audio; it never submits a verdict.
Run this after the phone log reports the full purity audio pack is prepared.
"""

from __future__ import annotations

import argparse
import os
import re
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path


def receiver_reachable() -> bool:
    try:
        with socket.create_connection(("127.0.0.1", 8766), timeout=1):
            return True
    except OSError:
        return False


def stop_receiver() -> None:
    result = subprocess.run(["netstat", "-ano"], capture_output=True, text=True,
                            timeout=15, check=True)
    pids = set(re.findall(r"^\s*TCP\s+\S+:8766\s+\S+\s+LISTENING\s+(\d+)\s*$",
                          result.stdout, flags=re.MULTILINE))
    if len(pids) != 1:
        raise RuntimeError(f"Expected one receiver listener, found {len(pids)}")
    os.kill(int(next(iter(pids))), signal.SIGTERM)


def restart_services(pc_root: Path) -> None:
    script = pc_root / "tools" / "restart-allday-services.ps1"
    command = ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
               "-File", str(script)]
    # The launcher starts long-lived children; inheritable pipe handles can keep
    # communicate() waiting after the launcher itself exits.
    result = subprocess.run(command, cwd=pc_root, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            timeout=90, check=False)
    if result.returncode:
        raise RuntimeError(f"Service restart failed with exit code {result.returncode}")


def wait_receiver(reachable: bool) -> None:
    for _ in range(20):
        if receiver_reachable() == reachable:
            return
        time.sleep(0.5)
    raise RuntimeError(f"PC receiver did not become {'reachable' if reachable else 'unreachable'}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pc-root", required=True, type=Path)
    parser.add_argument("--hdc", required=True)
    parser.add_argument("--device", required=True)
    args = parser.parse_args()
    root = args.pc_root.resolve()
    if not receiver_reachable():
        raise RuntimeError("PC receiver must be running before the offline test")
    stopped = False
    try:
        print("Stopping PC receiver for offline check", flush=True)
        stop_receiver()
        stopped = True
        wait_receiver(False)
        print("PC receiver stopped; checking phone", flush=True)
        subprocess.run([
            sys.executable, "-u", str(Path(__file__).with_name("test-purity-review-device.py")),
            "--hdc", args.hdc, "--device", args.device,
            "--pc-db", str(root / "state" / "v3" / "core.sqlite3"), "--offline",
        ], check=True, timeout=120)
    finally:
        if stopped:
            print("Restoring PC receiver", flush=True)
            restart_services(root)
            wait_receiver(True)
            print("PC receiver restored", flush=True)


if __name__ == "__main__":
    main()
