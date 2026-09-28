"""Run and verify the production phone page-loading Hypium case."""

import main
import sys
import time
from pathlib import Path
import xml.etree.ElementTree as ET


started = time.time()
case = "PhonePageLoadingOffline" if "--offline" in sys.argv[1:] else "PhonePageLoadingAcceptance"
main.main_process(f"run -l {case}")
reports = [path for path in Path("reports").glob("*/summary_report.xml")
           if path.stat().st_mtime >= started]
if not reports:
    raise SystemExit("No fresh page-loading report")
report = max(reports, key=lambda path: path.stat().st_mtime)
summary = ET.parse(report).getroot().attrib
if summary.get("tests") != "1" or any(int(summary.get(key, "0"))
                                      for key in ("errors", "failures", "disabled", "ignored", "unavailable")):
    raise SystemExit(f"Page-loading acceptance failed: {report}")
print(f"Page-loading acceptance PASS: {report}")
