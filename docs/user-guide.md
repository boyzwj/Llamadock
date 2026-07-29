# LlamaDock user guide

LlamaDock manages external `llama.cpp` tools and ordinary GGUF files. It does
not embed an inference engine, hide model files in a database, or kill
processes it did not start.

## Install

LlamaDock requires an Apple Silicon Mac with macOS 14 or later.

For a public release, download both the `LlamaDock-<version>-macOS-arm64.zip`
and matching `.sha256` file from GitHub Releases. In Terminal, change to the
download folder and run:

```bash
shasum -a 256 -c LlamaDock-<version>-macOS-arm64.zip.sha256
```

Open the ZIP, drag LlamaDock to Applications, and launch it from Finder. A
public release is Developer ID signed, notarized, and stapled; do not bypass
Gatekeeper for an unsigned copy obtained elsewhere.

## 1. Choose or install a runtime

Open **Runtimes**. LlamaDock discovers:

- managed releases installed by LlamaDock;
- Homebrew `llama` and `llama-server` pairs;
- a custom executable you explicitly select.

Use **Check Updates** to query the official `ggml-org/llama.cpp` GitHub
release. **Install & Activate** downloads the official macOS arm64 archive,
validates its structure and binaries, registers it atomically, and switches the
active managed runtime only after validation. Existing managed versions remain
available for **Roll Back**. Runtime updates never update the LlamaDock App.

Stop a running server before switching or installing a runtime.

## 2. Add a model

Open **Models** and choose one path:

- **Add Folder** bookmarks a folder and recursively scans `.gguf` files without
  moving them.
- **Open GGUF** or **File > Open GGUF Model** creates a Profile for one file.
- The **Hugging Face** source searches public GGUF repositories and accepts
  repository URLs or compact `owner/repo:quant` references.

Hugging Face downloads are resumable and survive relaunch. You can pause,
resume, or cancel them. LlamaDock validates declared sizes, available SHA-256
digests, and bounded GGUF structure before atomically importing files.
Split GGUF sets, an optional vision projector (`mmproj`), and an optional draft
model are grouped into one Profile.

For gated or private repositories, enter a Hugging Face token in Settings. The
token is stored as a macOS Keychain generic password, masked in the UI, never
written to Profiles or diagnostics, and removed when you clear it.

## 3. Configure a Profile

A model can have multiple Profiles. Typed fields cover the common server
options; **Extra Arguments** remains a token list and is never executed through
a shell. LlamaDock warns when the selected runtime does not advertise a typed
flag.

Review **Launch Command** before starting. The displayed command and actual
`Process` argument array are generated from the same source. Profiles are
readable, versioned JSON and can be imported or exported.

## 4. Run the server

Open **Servers** and choose **Start**, or use **Command-R**. LlamaDock:

1. verifies that the selected runtime and model still exist;
2. rejects an occupied host/port before launch;
3. starts one owned `llama-server` by absolute executable path;
4. waits for its health endpoint;
5. shows Ready, Degraded, or a concrete failure reason.

The page displays the API base URL, owned PID, runtime, CPU, resident memory,
threads, uptime, and bounded redacted stdout/stderr. Use **Open WebUI**,
**Copy API URL**, or **Copy Launch Command** as needed.

Use **Command-.** to stop. LlamaDock sends graceful termination only to its
owned process, waits for exit, escalates only that process if necessary, and
releases its model security scope. It never uses `killall`.

Useful shortcuts:

- **Command-1 / 2 / 3**: Overview / Runtimes / Models.
- **Command-Shift-L**: Server Logs.
- **Command-R**: Start Server.
- **Command-Option-R**: Restart Server.
- **Command-.**: Stop Server.
- **Command-O**: Open one GGUF model.

## Updates

Settings separates **LlamaDock App** and **llama.cpp Runtime** updates.
LlamaDock checks its GitHub Releases at most daily when enabled and opens the
verified GitHub release page for an explicit download. It does not silently
replace itself. Runtime update discovery and managed activation use a separate
control and storage transaction.

## Diagnostics and privacy

Use **Settings > Copy Redacted Diagnostics** when reporting a problem. The
report includes app/system versions, counts, selected IDs, download state,
server state, and owned-process metrics. It intentionally excludes:

- Hugging Face tokens and authorization headers;
- prompts and completions;
- launch arguments and paths embedded in commands;
- server log contents.

LlamaDock has no analytics, telemetry, advertising, or hosted account. See
[`PRIVACY.md`](../PRIVACY.md) for network endpoints, local storage, and data
removal.

## Troubleshooting

- **No runtime:** install an official managed release or select a matching
  custom `llama-server`.
- **Unsupported setting:** remove the field or choose a runtime that advertises
  the flag; unknown capability detection is shown rather than guessed.
- **Model missing after relaunch:** reconnect or re-add its folder. LlamaDock
  does not copy bookmarked external files.
- **401/403 from Hugging Face:** confirm repository access and replace the
  Keychain token.
- **Download checksum/structure failure:** retry from the repository; LlamaDock
  does not import the rejected file.
- **Endpoint occupied:** choose another Profile port or stop the external
  service yourself. LlamaDock will not terminate it.
- **Server degraded or failed:** copy redacted diagnostics and inspect the
  bounded server log. The previous runtime/model/profile remains untouched.
