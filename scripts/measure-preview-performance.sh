#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUTPUT="$ROOT/.build/preview-performance"
mkdir -p "$OUTPUT"
FIXTURE="$(mktemp -d "$ROOT/../.preview-performance-XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  Sources/CodeFlightApp/NativeCodePreview.swift \
  Sources/CodeFlightApp/FileSearchCount.swift \
  Sources/CodeFlightApp/FileSearchNavigation.swift \
  Sources/CodeFlightApp/NativeTextPreview.swift \
  Sources/CodeFlightApp/PreviewTrace.swift \
  Sources/CodeFlightApp/SyntaxHighlighter.swift \
  Tools/PreviewPerformanceProbe.swift -o "$OUTPUT/probe"
python3 - "$FIXTURE" "$OUTPUT" <<'PY'
import json, pathlib, statistics, subprocess, sys
fixture, output = map(pathlib.Path, sys.argv[1:])
for name, count in [('small.swift', 200), ('medium.swift', 10_000), ('large.swift', 120_000)]:
    with (fixture/name).open('w') as stream:
        for index in range(count):
            stream.write(f'let value{index} = "第{index}行🙂"\n')
(fixture/'minified.swift').write_text('let value = "' + 'x'*4_000_000 + '"')
with (fixture/'sparse.bin').open('wb') as stream:
    stream.truncate(2*1024**3)
rows = []
for file in sorted(fixture.iterdir()):
    for repetition in range(3):
        result = json.loads(subprocess.check_output([str(output/'probe'), str(file)], text=True))
        if not result.get('nonText'):
            cached = json.loads(subprocess.check_output([str(output/'probe'), str(file), '--cache'], text=True))
            for key in ['cacheColdMS', 'cacheRevisitMS', 'cacheReused', 'cacheResidentMB']:
                result[key] = cached[key]
        result['repetition'] = repetition
        rows.append(result)
(output/'latest.json').write_text(json.dumps(rows, indent=2)+'\n')
for name in sorted({r['file'] for r in rows}):
    samples = [r for r in rows if r['file'] == name]
    values = {key: round(statistics.median(r[key] for r in samples), 2)
              for key in ['readMS','prepareMS','installPaintMS','middlePaintMS','endPaintMS','preparedMB','residentMB','cacheColdMS','cacheRevisitMS','cacheResidentMB'] if key in samples[0]}
    if 'cacheReused' in samples[0]:
        values['cacheReused'] = all(r['cacheReused'] for r in samples)
    print(name, json.dumps(values), flush=True)
print('Component benchmark only; report:', output/'latest.json')
PY
