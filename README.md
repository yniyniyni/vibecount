# Vibe-Count

Vibe-Count is a lightweight, competitive dashboard for friends to track their daily AI token usage (Anthropic/Claude, OpenAI). The app runs silently in your macOS menu bar, and whoever burns the most tokens by the end of the day "wins".

## Features
- **Functional Minimalism:** Zero bloat, compact layout, clean typography.
- **Strict Apple HIG Adherence:** Native macOS menu bar presence.
- **Local-First Architecture:** Uses SwiftData for persistence.
- **Swift 6 Concurrency:** Strict concurrency enforcement.

## Requirements
- macOS 14+

## Development

To build and run tests:
```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
```

To run the application directly from the CLI:
```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run
```

## Firebase (cross-device leaderboard sync)

The app is local-first and runs fine without any setup — but without Firebase it
falls back to `MockSyncService` and you only see your own row. To sync a real
leaderboard with friends, each person needs a `GoogleService-Info.plist` in
`Sources/VibeCount/` (it is **gitignored**, so a fresh clone must supply its own).

Easiest path — run the helper, which finds a plist (an installed
`/Applications/VibeCount.app`, `~/Downloads/`, or a path you pass) and copies it
into place:
```bash
scripts/setup-firebase.sh                 # auto-detect
scripts/setup-firebase.sh /path/to/GoogleService-Info.plist
scripts/setup-firebase.sh --force         # overwrite an existing one
```

Manual path — download the plist from the Firebase console
(project `vibe-count-app-0703` → Project settings → Your apps → the Apple app
`com.vibecount.app` → `GoogleService-Info.plist`) and drop it into
`Sources/VibeCount/`. The expected keys are documented in
[`Sources/VibeCount/GoogleService-Info.plist.example`](Sources/VibeCount/GoogleService-Info.plist.example).

Then rebuild (`swift run`) and the flame icon's popover will show live friends.
