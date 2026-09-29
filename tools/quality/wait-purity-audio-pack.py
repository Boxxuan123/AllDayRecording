"""Wait for the phone's silent purity audio prefetch to cover every review task."""

from __future__ import annotations

import argparse
import re
import subprocess
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hdc", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--expected", required=True, type=int)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    deadline = time.monotonic() + args.timeout
    highest = 0
    while time.monotonic() < deadline:
        result = subprocess.run([args.hdc, "-t", args.device, "shell", "hilog -x -e purity-audio"],
                                capture_output=True, text=True, timeout=20, check=True)
        for completed, total in re.findall(r"\[purity-audio\] pass complete (\d+)/(\d+)", result.stdout):
            if int(completed) == int(total) == args.expected:
                print(f"PASS: {completed}/{total} target and context audio pairs prepared")
                return
        for completed, total in re.findall(r"\[purity-audio\] prepared (\d+)/(\d+)", result.stdout):
            if int(total) == args.expected and int(completed) > highest:
                highest = int(completed)
                print(f"Prepared {highest}/{args.expected}", flush=True)
        time.sleep(3)
    raise TimeoutError(f"Purity audio pack did not complete: last observed {highest}/{args.expected}")


if __name__ == "__main__":
    main()
