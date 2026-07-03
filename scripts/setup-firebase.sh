#!/usr/bin/env bash
#
# setup-firebase.sh — drop a real GoogleService-Info.plist into Sources/VibeCount/
# so the app builds with live Firebase (Firestore) sync. Without it the app still
# builds and runs, but falls back to MockSyncService (no cross-device leaderboard).
#
# Usage:
#   scripts/setup-firebase.sh [path/to/GoogleService-Info.plist]
#   scripts/setup-firebase.sh --force     # overwrite an existing config
#   scripts/setup-firebase.sh --help
#
# Source resolution order (first match wins):
#   1. an explicit path argument
#   2. an installed /Applications/VibeCount.app
#   3. ~/Downloads/GoogleService-Info.plist
# If none is found, prints how to download one from the Firebase console.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Sources/VibeCount/GoogleService-Info.plist"
TEMPLATE="$DEST.example"
EXPECTED_PROJECT="vibe-count-app-0703"
INSTALLED_APP="/Applications/VibeCount.app/Contents/Resources/GoogleService-Info.plist"

usage() {
	sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

FORCE=0
SRC_ARG=""
for arg in "$@"; do
	case "$arg" in
		--force) FORCE=1 ;;
		-h|--help) usage; exit 0 ;;
		-*) echo "Unknown option: $arg" >&2; usage; exit 2 ;;
		*) SRC_ARG="$arg" ;;
	esac
done

if [[ -f "$DEST" && $FORCE -eq 0 ]]; then
	echo "✅ Already configured: ${DEST/#$ROOT\//}"
	echo "   Re-run with --force to overwrite."
	exit 0
fi

# Collect candidate sources in priority order.
candidates=()
[[ -n "$SRC_ARG" ]] && candidates+=("$SRC_ARG")
candidates+=("$INSTALLED_APP" "$HOME/Downloads/GoogleService-Info.plist")

SRC=""
for c in "${candidates[@]}"; do
	if [[ -f "$c" ]]; then SRC="$c"; break; fi
done

if [[ -z "$SRC" ]]; then
	cat >&2 <<EOF
❌ No GoogleService-Info.plist found.

Download one from the Firebase console:
  console → project "$EXPECTED_PROJECT" → Project settings → Your apps
  → Apple app (com.vibecount.app) → GoogleService-Info.plist → Download

Then do ONE of:
  • save it to ~/Downloads/ and re-run this script
  • pass the path:  scripts/setup-firebase.sh /path/to/GoogleService-Info.plist
  • copy it by hand to: ${DEST/#$ROOT\//}

Key/value shape is documented in: ${TEMPLATE/#$ROOT\//}
EOF
	exit 1
fi

# Validate: must be a real plist that carries a PROJECT_ID.
if ! plutil -lint "$SRC" >/dev/null 2>&1; then
	echo "❌ Not a valid plist: $SRC" >&2
	exit 1
fi
project="$(/usr/libexec/PlistBuddy -c 'Print :PROJECT_ID' "$SRC" 2>/dev/null || true)"
if [[ -z "$project" ]]; then
	echo "❌ $SRC has no PROJECT_ID — is it really a GoogleService-Info.plist?" >&2
	exit 1
fi
if [[ "$project" != "$EXPECTED_PROJECT" ]]; then
	echo "⚠️  This plist targets project '$project', not '$EXPECTED_PROJECT'."
	echo "    Using it anyway (looks like your own Firebase project)."
fi

cp "$SRC" "$DEST"
echo "✅ Installed GoogleService-Info.plist"
echo "   from:    $SRC"
echo "   to:      ${DEST/#$ROOT\//}   (gitignored)"
echo "   project: $project"
echo
echo "Now build the .app bundle to pick up live Firebase sync:"
echo "  scripts/build-app.sh && open build/VibeCount.app"
echo
echo "(swift run does NOT sync: its plist lands in Bundle.module, but the app"
echo " looks in Bundle.main — only the .app bundle puts it where it's found.)"
