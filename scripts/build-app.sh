#!/usr/bin/env bash
#
# build-app.sh — wrap the SwiftPM executable in a real macOS .app bundle.
#
# A bare `swift run` binary has no Info.plist / CFBundleIdentifier, and Firebase
# will NOT sync in that context. This produces build/VibeCount.app with a proper
# bundle identity, the GoogleService-Info.plist in Contents/Resources (so
# FirebaseApp.configure() and Bundle.main find it), and LSUIElement=true so it
# stays a menu-bar-only app.
#
# Usage:
#   scripts/build-app.sh [debug|release]      # default: debug
# Then:
#   open build/VibeCount.app

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
BUNDLE_ID="com.vibecount.app"
APP="$ROOT/build/VibeCount.app"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/VibeCount"
[[ -x "$BIN" ]] || { echo "❌ executable not found: $BIN" >&2; exit 1; }

echo "▸ Assembling ${APP/#$ROOT\//}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VibeCount"

# SwiftPM resource bundle(s) so Bundle.module resolves.
for b in "$BIN_DIR"/*.bundle; do
	[[ -e "$b" ]] && cp -R "$b" "$APP/Contents/Resources/"
done

# GoogleService-Info.plist → Contents/Resources so Bundle.main + configure() find it.
# The plist lives at the repo root (gitignored); it is deliberately NOT a SwiftPM
# resource, so a fresh clone builds without missing-resource warnings.
PLIST_SRC="$ROOT/GoogleService-Info.plist"
if [[ -f "$PLIST_SRC" ]]; then
	cp "$PLIST_SRC" "$APP/Contents/Resources/GoogleService-Info.plist"
	echo "  • bundled GoogleService-Info.plist (live Firebase sync)"
else
	echo "  ⚠️  no GoogleService-Info.plist at the repo root — the app will run in"
	echo "     local-only mode. Run scripts/setup-firebase.sh first for real sync."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>VibeCount</string>
	<key>CFBundleDisplayName</key><string>Vibe-Count</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleExecutable</key><string>VibeCount</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so the bundle launches cleanly (best-effort). REST sync needs no
# entitlements, certificates, or provisioning profiles.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✅ Built ${APP/#$ROOT\//}"
echo "   Run it:  open ${APP/#$ROOT\//}"
