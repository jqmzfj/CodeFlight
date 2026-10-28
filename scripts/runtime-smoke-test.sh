#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build >/dev/null
./scripts/package-app.sh >/dev/null

python3 - <<'PY'
import os
import subprocess
import time

app = os.path.abspath("CodeFlight.app/Contents/MacOS/CodeFlight")
environment = dict(os.environ, CODEFLIGHT_SMOKE_TEST="1")
process = subprocess.Popen(app, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
time.sleep(2)
if process.poll() is not None:
    stderr = process.stderr.read().decode("utf-8", errors="replace")
    raise SystemExit(f"CodeFlight exited during startup ({process.returncode}): {stderr[:1000]}")
process.terminate()
try:
    process.wait(timeout=5)
except subprocess.TimeoutExpired:
    process.kill()
    process.wait(timeout=5)
if process.returncode not in (-15, 15):
    raise SystemExit(f"CodeFlight did not terminate cleanly: {process.returncode}")
print("CodeFlight runtime smoke test passed")
PY
