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
tracks only your own usage. To sync a leaderboard with friends you can either
use the **shared VibeCount cloud** or **self-host** a Firebase project:

- **VibeCount cloud (no Firebase setup):** first launch (or *Sync Settings…*) →
  **Use VibeCount cloud**. Joins the shared project (`vibe-count-app-0703`)
  and **requires Sign in with Google** so your identity survives reinstalls.
  Friends use invite codes / join links as usual on that shared backend.
- **Host (self-host):** pick *Host your own group* and follow the guided
  steps — the app opens the right Firebase console pages, gives you the
  security rules to paste, validates the setup, and hands you a join link.
- **Join (self-host):** click the `vibecount://join?…` link your host sent
  (or paste it into *Join a self-hosted group*). The host is added as a
  friend automatically.
- **Optional Google sign-in:** if the host completes wizard step 6 (their own
  Desktop OAuth client), members can click *Sign in with Google* in Sync
  Settings to link their identity — reinstalling or moving to a new Mac then
  recovers the same stats, friends, and invite code by signing in again.

A `GoogleService-Info.plist` bundled by `scripts/build-app.sh` still works as
a fallback backend (`scripts/setup-firebase.sh` installs one), but a stored
GUI config (including VibeCount cloud) takes precedence when both exist.

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
