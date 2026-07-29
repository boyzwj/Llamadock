# LlamaDock

LlamaDock is a native macOS manager for external `llama.cpp` runtimes, transparent
GGUF model files, reusable server profiles, and owned `llama-server` processes.
It does not link or reimplement `llama.cpp`.

The project follows the architecture and milestones in [DESIGN.md](DESIGN.md).

## Status

Milestone 0 is complete. Milestone 1 now provides the external-runtime vertical
slice: Homebrew and custom runtime discovery, capability probes, local GGUF
selection, readable JSON profiles, exact launch-command previews, one owned
`llama-server` process, bounded redacted logs, health polling, and WebUI access.

The Milestone 1 acceptance gate remains open until the full
start → ready → OpenAI-compatible API → stop flow is qualified with a real small
GGUF model and no orphaned process.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Swift 6
- Xcode 16 or later

The initial skeleton was verified with Swift 6.4 and Xcode 26.6 on Apple Silicon.

## Build and test

```bash
swift test --package-path Packages/LlamadockCore

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild \
  -project Llamadock.xcodeproj \
  -scheme Llamadock \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Open `Llamadock.xcodeproj` in Xcode to run the app.

## Repository layout

```text
App/                         SwiftUI app entry and shared app state
Features/                    Overview, Runtimes, Models, Servers, Settings
Packages/LlamadockCore/      Foundation-only core package and unit tests
docs/adr/                    Architecture decision records
Scripts/                     Development and smoke-test scripts
```

## Product naming

- Display name: **LlamaDock**
- Repository/directory: `Llamadock`
- Core Swift module: `LlamadockCore`
- Bundle identifier: `io.github.boyzwj.LlamaDock`

## License

MIT. See [LICENSE](LICENSE). Third-party attribution is tracked in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
