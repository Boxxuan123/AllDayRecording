import main
import argparse
import time
from pathlib import Path
import xml.etree.ElementTree as ET

started = time.time()
parser = argparse.ArgumentParser()
parser.add_argument('--resume', action='store_true')
args = parser.parse_args()
main.main_process('run -l PhoneSyncTargetedResume' if args.resume else 'run -l PhoneSyncTargeted')
reports = [p for p in Path('reports').glob('*/summary_report.xml') if p.stat().st_mtime >= started]
if not reports:
    raise SystemExit('No fresh native acceptance report')
report = max(reports, key=lambda p: p.stat().st_mtime)
summary = ET.parse(report).getroot().attrib
if summary.get('tests') != '1' or any(int(summary.get(key, '0')) for key in ('errors','failures','disabled','ignored','unavailable')):
    raise SystemExit(f'Native acceptance failed: {report}')
print(f'Native acceptance PASS: {report}')
