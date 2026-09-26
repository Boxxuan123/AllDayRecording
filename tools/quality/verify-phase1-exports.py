"""Hash two read-only phone exports; filenames remain in private local manifests."""
import hashlib
import json
import pathlib
import sys


def manifest(root):
    records = {}
    for file in sorted(root.rglob('*')):
        if file.is_file():
            with file.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            records[file.relative_to(root).as_posix()] = [file.stat().st_size, digest]
    root.with_suffix('.manifest.json').write_text(json.dumps(records), encoding='utf-8')
    return records


a, b = (pathlib.Path(value).resolve(strict=True) for value in sys.argv[1:3])
left, right = manifest(a), manifest(b)
changed = sum(left.get(key) != right.get(key) for key in left.keys() | right.keys())
print(json.dumps({'count_a': len(left), 'count_b': len(right), 'bytes_a': sum(v[0] for v in left.values()),
                  'bytes_b': sum(v[0] for v in right.values()), 'different_files': changed}))
sys.exit(1 if changed else 0)
