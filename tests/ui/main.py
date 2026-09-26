"""从 tests/ui 目录运行：python main.py。"""

import os
from pathlib import Path


# DevEco Testing 桌面版自带 hdc，Hypium 通过 PATH 查找它。
bundled_hdc = Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "DevEco Testing/app/resources/bin"
if (bundled_hdc / "hdc.exe").is_file():
    os.environ["PATH"] = str(bundled_hdc) + os.pathsep + os.environ.get("PATH", "")

from xdevice.__main__ import main_process


if __name__ == "__main__":
    main_process("run -l PhoneMoreSmoke")
