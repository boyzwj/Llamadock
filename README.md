# LlamaDock

LlamaDock is a native macOS manager for external `llama.cpp` runtimes, transparent
GGUF model files, reusable server profiles, and owned `llama-server` processes.
It does not link or reimplement `llama.cpp`.

The project follows the architecture and milestones in [DESIGN.md](DESIGN.md).

## Status

Milestones 0 and 1 are complete. The external-runtime vertical slice provides
Homebrew and custom runtime discovery, capability probes, local GGUF selection,
readable JSON profiles, exact launch-command previews, one owned
`llama-server` process, occupied-port preflight, bounded redacted logs, health
polling, and WebUI access.

The Milestone 1 acceptance flow is qualified end to end with official
`llama.cpp` and GGUF artifacts: select runtime and model → preview the exact
command → start → ready → OpenAI-compatible completion → stop, with the owned
PID and listening socket gone afterward. Profiles restore after relaunch.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Swift 6
- Xcode 16 or later

The Milestone 1 gate was verified on Apple Silicon with macOS 27.0
(26A5388g), Xcode 26.6 (17F113), and its bundled Swift 6.3.3 toolchain.

## Build and test

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift test --package-path Packages/LlamadockCore

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

## Real-runtime smoke test

Provide absolute paths to a `llama-server` executable and a small local GGUF:

```bash
LLAMADOCK_LLAMA_SERVER=/absolute/path/to/llama-server \
LLAMADOCK_MODEL=/absolute/path/to/model.gguf \
Scripts/smoke-real-runtime.sh
```

The script checks `/health`, `/v1/models`, and `/v1/completions`, then
terminates only the PID it launched and verifies that no owned process or
listening socket remains. `LLAMADOCK_SMOKE_PORT` and
`LLAMADOCK_READINESS_TIMEOUT` are optional.

The recorded Milestone 1 qualification used:

- [`llama.cpp` b10176](https://github.com/ggml-org/llama.cpp/releases/tag/b10176),
  revision `f5b9bd39b`, macOS arm64 archive SHA-256
  `4cc6d269c28126c2c9f946601f74f3ceab07f785b8a61d9d795f314937993775`
- [`ggml-org/tiny-llamas` `stories15M-q4_0.gguf`](https://huggingface.co/ggml-org/tiny-llamas/blob/main/stories15M-q4_0.gguf),
  SHA-256
  `6151b1929d7f5aa3385d9ddef3393e55587c0a55de661562322bc51dfda93a04`
- 44 core tests, the macOS Debug app build, a real completion request, owned
  process shutdown, persistence after relaunch, and occupied-port rejection
  before process launch

## Current limitations

- Milestone 1 manages external runtimes and local model files. Managed runtime
  installation, resumable model downloads, and the full library arrive in later
  milestones.
- Runtime and model files remain in their original locations. Moving or deleting
  them makes the saved profile invalid until a replacement is selected.
- The app currently uses a 30-second cold-probe budget because first launch of
  an official macOS runtime can initialize platform backends slowly.
- Development builds are unsigned. Release signing, notarization, packaging,
  update delivery, and release qualification are Milestone 5 work.

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
