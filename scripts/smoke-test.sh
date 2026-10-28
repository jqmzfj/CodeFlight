#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build >/dev/null
swift test >/dev/null
test -x .build/debug/CodeFlight
./scripts/package-app.sh >/dev/null
codesign --verify --deep --strict CodeFlight.app

TEST_DIR="$(mktemp -d "$ROOT/../.codeflight-smoke-XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cd "$TEST_DIR"
git init -q -b main
git config user.email smoke@example.com
git config user.name Smoke
printf 'hello\n' > README.md
git add README.md
git commit -qm initial
printf 'world\n' >> README.md
git add README.md
git stash push -qm smoke
test "$(git stash list --format='%gd|%s')" = "stash@{0}|On main: smoke"
git stash apply -q
git restore --source=HEAD --worktree -- README.md
git tag smoke-tag
git tag -d smoke-tag >/dev/null
echo "CodeFlight smoke test passed"
