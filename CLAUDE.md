# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Use Context7 MCP when you need library/API documentation (Firebase SDK, SwiftData, AppKit) or setup/configuration steps, without me having to explicitly ask.

## Project Overview

**Vibe-Count** — a macOS **menu bar** app that turns daily AI token usage into a competitive leaderboard among friends: whoever burns the most Claude tokens by end of day "wins". It runs silently in the status bar, showing your own daily total as the button title.

- **Platform**: macOS 14+ (Apple Silicon / Intel)
- **Language**: English (all UI text, code, and comments are in English)
- **Architecture stance**: local-first (SwiftData) with optional cross-device sync via Firebase Firestore; Swift 6 strict concurrency; functional-minimalist UI following Apple HIG.

## Tech Stack

- **Swift Package Manager** executable target (`VibeCount`), `swift-tools-version: 5.10`
- **Swift 6 concurrency** opted in via `.enableUpcomingFeature("StrictConcurrency")` — checked under the Swift 5 language mode
- **SwiftUI** for the popover content (`DashboardView`) + **AppKit** for the menu-bar lifecycle (`NSStatusItem`, `NSPopover`, `NSApplicationDelegate`)
- **SwiftData** (`@Model` classes in `Models/Schema.swift`) for local persistence
- **Firebase Firestore** (`firebase-ios-sdk` 11.x, `.upToNextMajor(from: 11.0.0)`) for the shared leaderboard
- **XCTest** for unit/UI tests

## Commands

The README pins builds to **Xcode-beta** via `DEVELOPER_DIR`. Prefix commands with it when the default toolchain is too old:

| Command | Description |
| --- | --- |
| `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build` | Build |
| `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run` | Build & run the menu-bar app from the CLI |
| `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test` | Run the full test suite |
| `swift test --filter VibeCountTests.ModelTests/testModelCreation` | Run a single test (Suite.Class/method) |
| `swift test --filter UsageMonitorTests` | Run one test class |
| `firebase deploy --only firestore:rules` | Deploy Firestore security rules (project `vibe-count-app-0703`) |

**Required to build/run with real sync:** drop a `GoogleService-Info.plist` (from the Firebase console) into `Sources/VibeCount/`. It is **gitignored** and declared as a `.process` resource in `Package.swift`, so a fresh clone must supply it before building. Without it at runtime, the app logs a warning and falls back to `MockSyncService`.

## Project Structure

```
Sources/VibeCount/
├── VibeCountApp.swift            # @main App shell + AppDelegate (the real entry point)
├── Models/Schema.swift           # SwiftData @Model types: User, Friend, TokenLog
├── Services/
│   ├── UsageMonitor.swift        # UsageMonitor protocol + MockUsageMonitor
│   ├── ClaudeUsageMonitor.swift  # Real monitor — parses ~/.claude/projects/**/*.jsonl
│   └── SyncService.swift         # SyncService protocol + Firebase & Mock implementations
├── UI/
│   ├── DashboardView.swift       # SwiftUI popover: leaderboard + Today/Monthly + actions
│   └── VisualEffectView.swift    # NSViewRepresentable blur wrapper (currently unused by DashboardView)
└── GoogleService-Info.plist      # (gitignored) Firebase config — you provide this

Tests/VibeCountTests/             # XCTest: AppTests, ModelTests, UsageMonitorTests, UIViewTests
firestore.rules / firestore.indexes.json / firebase.json / .firebaserc   # Firebase project config
```

## Architecture

### App lifecycle — SwiftUI shell, AppKit engine

The SwiftUI `App` (`VibeCountApp`) declares only a `Settings { EmptyView() }` scene — **there is no real window**. All behavior lives in `AppDelegate` (wired via `@NSApplicationDelegateAdaptor`). `applicationDidFinishLaunching` does everything:

1. Creates the `ModelContainer(for: User, Friend, TokenLog)` and purges legacy/mock `Friend` rows (`mock1`, `mock2`, `localUser`).
2. Configures Firebase if `GoogleService-Info.plist` exists → `FirebaseSyncService`; otherwise `MockSyncService` (seeds fake "Alice"/"Bob").
3. Builds the `NSStatusItem` (flame icon) + a transient `NSPopover` hosting `DashboardView` (injected with the shared `ModelContainer`).
4. Installs a global mouse monitor to auto-close the popover on outside clicks.
5. Registers `NotificationCenter` observers and starts a **600 s polling timer** (`pollUsage`), also firing once immediately.

### SwiftUI → AppDelegate communication is via NotificationCenter

`DashboardView` lives inside the popover and cannot call `AppDelegate` directly. Buttons post named notifications — `"AddFriend"` and `"RefreshData"` — which `AppDelegate` observes (`addFriend`, `manualRefresh`). Quit calls `NSApplication.shared.terminate` directly. **Follow this pattern for any new popover→app action** rather than reaching for shared singletons.

### Usage data flow (the core loop)

`pollUsage()` (timer-driven, and on `RefreshData`):
`usageMonitor.fetchDailyUsage()/fetchMonthlyUsage()` → format the daily total (`k`/`M`/`B`) into the menu-bar button title → `getOrCreateLocalUser()` → `syncService.pushLocalUsage(...)`.

- **`UsageMonitor` protocol** (`Sendable`) has two impls; `AppDelegate` hardcodes `ClaudeUsageMonitor`. `MockUsageMonitor` returns fixed numbers and is used by tests.
- **`ClaudeUsageMonitor`** enumerates `~/.claude/projects/**/*.jsonl`, keeps only assistant lines with a `usage` block, and sums `input_tokens + cache_creation_input_tokens + cache_read_input_tokens + output_tokens`. **Rows are de-duplicated per file by `"<messageId>:<requestId>"`** to avoid double-counting streamed/retried assistant turns; rows missing those ids are summed directly. Daily = since `startOfDay`; monthly = trailing 30 days. (The `historyURL`/`dateFormatter` set in `init` are currently unused dead fields.)

### Sync — SwiftData is the UI source of truth, Firestore is the transport

`SyncService` is `@MainActor`. Both `pushLocalUsage` and the incoming Firestore snapshot **upsert `Friend` rows into SwiftData**, and `DashboardView` renders straight from a `@Query`. So the UI never reads Firestore directly.

- **`FirebaseSyncService.startSyncing`** attaches an `addSnapshotListener` to the **entire `users` collection** and upserts every document into a local `Friend` (keyed by `documentID`). Consequence to know: the leaderboard shows *all* app users automatically — "Add Friend" (entering an invite code) just pre-creates a `"Loading..."` placeholder row that the next snapshot fills in.
- **`pushLocalUsage`** writes the local `Friend` first (instant UI), then `setData(merge: true)` to `users/{userId}`.
- The **local user is also a `Friend` row** (same collection/table), flagged as "(You)" in the UI. `DashboardView` sorts by `latestDailyTokens` descending.

### Identity — no auth

There is no login. `getOrCreateLocalUser()` lazily creates a single `User` with an 8-char lowercased UUID prefix used as **both `userId` and `inviteCode`**, and `displayName = NSFullUserName()`. Friends are shared by handing someone your invite code. Firestore rules are intentionally open (`allow read, write: if true`) for this small friends-only leaderboard — see `firestore.rules`.

## Data Models (`Models/Schema.swift`)

- **`User`** — unique `userId`, `displayName`, `inviteCode`. Exactly one row (the local user).
- **`Friend`** — unique `friendId`, `latestDailyTokens`, `latestMonthlyTokens`, `lastUpdated`. The leaderboard row for **both** self and friends; this is what the UI queries.
- **`TokenLog`** — `id`, `timestamp`, `tokensBurned`, `model`. Declared in the schema but not yet written anywhere (reserved for future per-event history).

## Firestore Schema

Collection **`users`**, document id = `userId`. Fields written by `pushLocalUsage`:
`displayName: String`, `latestDailyTokens: Int`, `latestMonthlyTokens: Int`, `lastUpdated: serverTimestamp()`. Firebase project: `vibe-count-app-0703` (`.firebaserc`).

## Testing

- **XCTest**, files under `Tests/VibeCountTests/`. Run with the Xcode-beta `DEVELOPER_DIR` prefix (see Commands).
- SwiftData tests use an **in-memory** container: `ModelConfiguration(isStoredInMemoryOnly: true)`.
- `UIViewTests` renders `DashboardView` through an `NSHostingController` and asserts the fixed **300×400** fitting size — keep that frame in sync if the layout changes.
- Tests exercise the mocks (`MockUsageMonitor`), never live Firebase or the real `~/.claude` filesystem.

## Conventions

- **Menu-bar-only app**: keep all interactive UI inside the popover's `DashboardView`; there is no main window and no dock/window management configured in the SPM package.
- **Protocol + Mock pairs**: services (`UsageMonitor`, `SyncService`) are protocols with a real and a `Mock` implementation, selected in `AppDelegate` at launch. Add new external integrations the same way so they stay testable and degrade gracefully when unconfigured.
- **Concurrency**: UI/AppDelegate/`SyncService` are `@MainActor`; background work uses `async`/`await` and `Task { @MainActor in ... }` to hop back. `FirebaseFirestore` is imported `@preconcurrency`. Keep new types `Sendable`-clean under strict concurrency.
- **Token formatting** (`k`/`M`/`B`, stripping trailing `.0`) is duplicated in `AppDelegate.pollUsage` and `DashboardView.formatTokens` — update both if the format changes.
