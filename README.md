# LlamaDock

LlamaDock is a native macOS manager for external `llama.cpp` runtimes, transparent
GGUF model files, reusable server profiles, and owned `llama-server` processes.
It does not link or reimplement `llama.cpp`.

The project follows the architecture and milestones in [DESIGN.md](DESIGN.md).

## Status

Milestones 0 through 4 are complete. In addition to the external-runtime
vertical slice, LlamaDock can query and cache the official latest `llama.cpp`
release, securely download and extract its macOS arm64 archive, validate its
Mach-O binaries and reported build, atomically register it, activate it, and
roll back to the previous managed version.

The Milestone 1 acceptance flow is qualified end to end with official
`llama.cpp` and GGUF artifacts: select runtime and model → preview the exact
command → start → ready → OpenAI-compatible completion → stop, with the owned
PID and listening socket gone afterward. Profiles restore after relaunch.

The Milestone 2 flow is also qualified through the real macOS UI: check the
official GitHub release → install and validate `b10176` → persist an active
managed registry → relaunch from the validated release cache → start the
managed runtime → complete an OpenAI-compatible request → stop and release the
socket. Simulated verification, registration, and activation failures cover
the non-destructive rollback boundaries.

The Milestone 3 model library recursively scans the app-owned model directory
and bookmarked external folders, reads bounded GGUF v2/v3 metadata without
loading tensor data, keeps invalid files visible, and restores multiple
versioned launch profiles. Typed settings are checked against the selected
runtime's advertised flags while extra arguments remain tokenized and
shell-free.

Milestone 4 adds browsing for public and authenticated Hugging Face GGUF
repositories. It normalizes repository URLs and `llama -hf` references, pages
through the real file tree, and groups quantizations, split artifacts, vision
projectors, and draft models. Optional Hub credentials are masked in the UI and
stored only as a macOS Keychain generic password.
Main artifacts can be queued, paused, resumed after relaunch with HTTP Range,
cancelled, bundled with optional mmproj/draft companions, checked against exact
sizes, available Hub SHA-256 digests, and bounded GGUF structure validation,
then atomically imported without overwriting existing files. Completion creates
and selects a launch Profile, including companion paths, and reconciliation
repairs a missing Profile after an interrupted app exit.

The full core suite currently has 132 tests across 38 suites. The Milestone 4
real-delivery qualification downloaded `stories15M-q4_0.gguf` through the
production transport, verified and imported it, generated a Profile, started
official `llama.cpp` b10176, completed an OpenAI-compatible request, and stopped
without leaving its port occupied.

Milestone 5 is in progress. The app now reports version `1.0.0`, checks this
project's GitHub Releases separately from `llama.cpp` runtime updates, and can
copy a comprehensive redacted diagnostic report without credentials, prompts,
launch arguments, or server log contents. The release boundary is explicitly
non-sandboxed with Hardened Runtime. The owned server view and diagnostics now
report bounded PID-specific CPU, resident memory, thread count, and uptime;
task counters are sampled at a two-second cadence while log changes reach the UI
in 500 ms batches. Primary server controls, status, metrics, and logs expose
VoiceOver semantics. Public artifacts still require Developer ID signing and
Apple notarization. A tag-triggered release workflow now enforces Developer ID,
Hardened Runtime, notarization, stapling, Gatekeeper assessment, arm64-only
packaging, dSYMs, and SHA-256 checks before it can create a GitHub Release. The
App also has a complete native macOS AppIcon asset set.

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

Signed release prerequisites, repository secrets, packaging, notarization, and
rollback procedures are documented in [RELEASE.md](RELEASE.md). Release
qualification evidence is recorded in
[docs/release-qualification.md](docs/release-qualification.md).

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

## Real Hugging Face smoke test

Public Hub search and tree parsing can be checked without a token or model
download:

```bash
LLAMADOCK_HF_SMOKE_QUERY=stories15M \
LLAMADOCK_HF_SMOKE_REPOSITORY=mradermacher/llama2.c-stories15M-GGUF \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift test \
  --package-path Packages/LlamadockCore \
  --filter RealHuggingFaceHubSmokeTests
```

The test is skipped unless both `LLAMADOCK_HF_SMOKE_*` variables are present.

The Keychain adapter also has an opt-in smoke that writes, replaces, reads, and
removes an isolated synthetic item:

```bash
LLAMADOCK_KEYCHAIN_SMOKE=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift test \
  --package-path Packages/LlamadockCore \
  --filter RealHuggingFaceKeychainSmokeTests
```

The production download transport can be checked against a deterministic local
HTTP fixture. It covers a valid `206 Content-Range`, a server that ignores
Range and returns `200`, and a mismatched Content-Range that must be rejected
before any bytes are appended:

```bash
python3 Scripts/range-http-fixture.py --port 18081

LLAMADOCK_RANGE_SMOKE_URL=http://127.0.0.1:18081/model.gguf \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift test \
  --package-path Packages/LlamadockCore \
  --filter RealModelDownloadTransportSmokeTests
```

The full public-Hub delivery gate is opt in because it downloads a 19 MB model
and launches a real server:

```bash
LLAMADOCK_HF_DELIVERY_SMOKE=1 \
LLAMADOCK_HF_DELIVERY_SERVER=/absolute/path/to/llama-server \
LLAMADOCK_HF_DELIVERY_PORT=18082 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift test \
  --package-path Packages/LlamadockCore \
  --filter RealHuggingFaceDeliverySmokeTests
```

It downloads the public `ggml-org/tiny-llamas` `stories15M-q4_0.gguf`,
validates its declared size and SHA-256 plus its GGUF structure, imports it,
builds a Profile, waits for readiness, requests `/v1/completions`, and stops
only the process it launched.

Download state is readable versioned JSON at
`~/Library/Application Support/Llamadock/downloads/state.json`. Partial files
live under `downloads/jobs/<job-id>/` and are removed after successful import
or cancellation. Completed artifacts are stored under
`models/huggingface/<owner>/<repository>/<revision>/`.

## Managed runtime storage

LlamaDock owns a transparent runtime directory under
`~/Library/Application Support/Llamadock/runtimes/`:

- `registry.json` records installed, active, and previous runtime IDs;
- `<tag>-macos-arm64/` contains each validated release;
- `downloads/` contains only in-progress transaction directories and is cleaned
  after success or failure.

The app checks for updates at most once per day by default, restores a validated
release cache without a network request between checks, and never switches a
running LlamaDock server. Manual Check Updates, Install & Activate, Activate
Selected, Roll Back, and Copy Diagnostics controls are available in Runtimes.

## Current limitations

- Managed runtime deletion and automatic retention pruning are not exposed yet.
- Downloads use one URLSession stream per file. Configurable multi-segment Range
  concurrency remains a post-v1 performance enhancement.
- Runtime and model files remain in their original locations. Moving or deleting
  them makes the saved profile invalid until a replacement is selected.
- The app currently uses a 30-second cold-probe budget because first launch of
  an official macOS runtime can initialize platform backends slowly.
- This repository currently has no configured Developer ID certificate or
  notarization secrets, so a public v1 artifact cannot yet be produced. The
  release workflow fails closed until those credentials are configured.
- Final qualification still requires real smoke results from two Apple Silicon
  generations with different memory capacities.

## Privacy and release security

LlamaDock has no analytics, advertising, telemetry, or hosted account service.
See [PRIVACY.md](PRIVACY.md) for local storage, network, diagnostic, and deletion
behavior. The v1 signing, sandbox, and update boundary is recorded in
[ADR 0007](docs/adr/0007-release-security-and-update-boundary.md).

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
