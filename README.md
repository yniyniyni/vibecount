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
