# VibeCount

**A native macOS menu-bar leaderboard for Claude Code token usage.**

VibeCount reads Claude Code and Codex session logs on your Mac, shows how many
tokens you have used today and over the last 30 days, and optionally syncs
those aggregate totals with friends.

## What it does

- Lives in the macOS menu bar with your current daily token count.
- Reads local Claude Code logs from `~/.claude/projects` and OpenAI Codex CLI
  logs from `~/.codex/sessions` and `~/.codex/archived_sessions`.
- Combines Claude Code and Codex token usage into one daily and 30-day total.
- Ranks today and rolling 30-day usage in a compact native dashboard.
- Shows a local **Stats** tab: your own tokens per day over the last 30 days
  and a breakdown by model (Opus, Sonnet, Haiku, Codex).
- Works locally with no account or backend.
- Syncs leaderboards through the shared VibeCount cloud or a self-hosted
  Firebase project.
- Adds friends with invite codes or self-hosted join links.

Raw prompts and session logs never leave your Mac. When sync is enabled,
VibeCount uploads your macOS display name, daily token total, rolling 30-day
total, and update timestamp.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer with the Swift 6 toolchain
- Claude Code usage logs for nonzero totals

## Build and run

Build the macOS app bundle:

```bash
scripts/build-app.sh release
open build/VibeCount.app
```

The first launch offers three modes:

| Mode | Setup | Behavior |
| --- | --- | --- |
| Local only | None | Stores and displays only this Mac's usage. |
| VibeCount cloud | Google sign-in | Syncs aggregate usage through the shared Firebase project. |
| Self-hosted | Your Firebase project | Uses the guided setup wizard and bundled security rules. |

`swift run` is useful during development, but it creates a bare executable. It
does not register the `vibecount://` join-link scheme or embed a repository-root
`GoogleService-Info.plist`. A sync configuration previously saved through the
app can still work with the bare executable.

## Sync behavior

VibeCount refreshes at launch, every 10 minutes, whenever the popover opens,
and when you press `Command-R`. Sync uses the Firestore REST API and polling;
there are no realtime listeners or offline write queue.

For self-hosted sync, the in-app wizard walks through:

1. Creating a Firebase project and Firestore database.
2. Enabling Anonymous Authentication.
3. Publishing the included Firestore security rules.
4. Entering the project ID and Web API key.
5. Optionally enabling Google sign-in for identity recovery.

A bundled `GoogleService-Info.plist` remains available as a legacy fallback:

```bash
scripts/setup-firebase.sh /path/to/GoogleService-Info.plist
scripts/build-app.sh release
```

Stored in-app configuration takes precedence over the bundled plist.

Deployed rules are not kept in sync automatically: after editing
`firestore.rules`, republish it from the Firebase console (Firestore
Database → Rules) on every project using it, including the shared VibeCount
cloud project. There's no way to tell from this repository alone whether a
given deployment's rules match the current file.

## Development

Run the Swift test suite:

```bash
swift test
```

Check that a tracked-files-only checkout has a valid Swift package:

```bash
bash scripts/check-clean-clone.sh
```

Run Firestore security-rule tests with Node.js 20+ and JDK 21+:

```bash
cd firestore-tests
npm ci
npm test
```

## Release status

The repository currently builds an ad-hoc-signed development bundle. It does
not yet contain a Developer ID signing, hardened runtime, notarization, release
CI, installer, or automatic-update pipeline. See the
[production-hardening plan](docs/superpowers/plans/2026-07-17-production-hardening.md)
before shipping a public release.
