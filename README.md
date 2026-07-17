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
swift test
```

To run the application directly from the CLI:
```bash
swift run
```

## Firebase (cross-device leaderboard sync)

The app is local-first and runs fine without any setup — without a backend it
tracks only your own usage. To sync a leaderboard with friends, one person
**hosts** a (free) Firebase project and everyone else **joins** it:

- **Host:** first launch opens a setup window (also reachable later via
  *Sync Settings…* in the popover). Pick *Host a group* and follow the guided
  steps — the app opens the right Firebase console pages, gives you the
  security rules to paste, validates the setup, and hands you a join link.
- **Join:** click the `vibecount://join?…` link your host sent (or paste it
  into *Join a group*). The host is added as a friend automatically.

A `GoogleService-Info.plist` bundled by `scripts/build-app.sh` still works as
a fallback backend (`scripts/setup-firebase.sh` installs one), but the GUI
setup takes precedence when both exist.

### Running with live sync

`swift run` produces a bare executable with **no** app bundle, and Firebase does
**not** sync in that context (you'd see only your own row, no error). Build a real
`.app` bundle instead:
```bash
scripts/build-app.sh          # → build/VibeCount.app (embeds the plist)
open build/VibeCount.app
```
The flame icon's popover then shows live friends with updating token counts. Use
`swift run` for local logic/dev; use the bundle for anything touching Firebase.
