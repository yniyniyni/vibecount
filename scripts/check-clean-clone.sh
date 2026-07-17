#!/usr/bin/env bash
#
# check-clean-clone.sh — verify that a fresh, tracked-files-only checkout is
# healthy: the SwiftPM manifest parses without diagnostics, every resource or
# exclude path it declares actually exists in the clone (the failure mode that
# used to warn about a missing GoogleService-Info.plist), and no service plist
# is accidentally tracked.
#
# Hermetic: uses `git archive` + `swift package dump-package`, so it needs no
# network and resolves no dependencies.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

git -C "$ROOT" archive HEAD | tar -x -C "$TMP"

if git -C "$ROOT" ls-files | grep -E '^Sources/.*GoogleService-Info\.plist$' | grep -qv '\.example$'; then
	echo "❌ a GoogleService-Info.plist is tracked under Sources/ — it must stay gitignored" >&2
	exit 1
fi

DUMP_ERR="$TMP/dump-stderr.txt"
if ! (cd "$TMP" && swift package dump-package >"$TMP/dump.json" 2>"$DUMP_ERR"); then
	echo "❌ swift package dump-package failed on a clean clone:" >&2
	cat "$DUMP_ERR" >&2
	exit 1
fi
if grep -Eiq 'warning|error' "$DUMP_ERR"; then
	echo "❌ swift package dump-package emitted diagnostics on a clean clone:" >&2
	cat "$DUMP_ERR" >&2
	exit 1
fi

python3 - "$TMP" <<'PY'
import json, os, sys

tmp = sys.argv[1]
with open(os.path.join(tmp, "dump.json")) as f:
    manifest = json.load(f)

missing = []
for target in manifest.get("targets", []):
    base = target.get("path")
    if not base:
        root = "Tests" if target.get("type") == "test" else "Sources"
        base = os.path.join(root, target["name"])
    for resource in target.get("resources") or []:
        path = os.path.join(tmp, base, resource["path"])
        if not os.path.exists(path):
            missing.append(os.path.relpath(path, tmp))
    for exclude in target.get("exclude") or []:
        path = os.path.join(tmp, base, exclude)
        if not os.path.exists(path):
            missing.append(os.path.relpath(path, tmp))

if missing:
    print("❌ manifest references files a fresh clone doesn't have:", file=sys.stderr)
    for path in missing:
        print(f"   {path}", file=sys.stderr)
    sys.exit(1)
PY

echo "✅ clean clone OK: manifest parses cleanly and references no missing files"
