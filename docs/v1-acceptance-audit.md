# LlamaDock v1 acceptance audit

This document maps every checklist item in `DESIGN.md` section 25 to current,
inspectable evidence. A checked item means its product behavior is implemented
and has automated or recorded real-runtime evidence. It does not replace the
signed-candidate and two-machine record in `release-qualification.md`.

Last source audit: 2026-07-30.

## Runtime

- [x] Managed, Homebrew, and custom discovery:
  `RuntimeCandidateDiscovery` plus `RuntimeCandidateDiscoveryTests`.
- [x] Real version/build display: `RuntimeProbe`, `RuntimesView`, probe fixture
  tests, and the recorded b10176 real-runtime qualification.
- [x] Upstream latest query: `GitHubLatestRuntimeReleaseClient` covers ETag,
  cache, rate-limit/error mapping, and official asset selection.
- [x] Official macOS arm64 installation: `ManagedRuntimeInstaller` performs the
  download, archive inspection, extraction, Mach-O/build validation, atomic
  registration, and activation transaction.
- [x] Failed installation leaves active unchanged: installer failure-boundary
  tests cover verification, registration, and activation failures.
- [x] Activation and rollback: `JSONManagedRuntimeRegistry` persists distinct
  active and previous pointers with round-trip tests.
- [x] Custom runtime files are never overwritten or deleted: custom candidates
  are probe-only; install and removal operations accept only validated direct
  children of the App-owned runtime root.
- [x] Older inactive managed runtimes can be deleted explicitly. Active,
  previous, and in-use runtimes are rejected in both the App and registry, and
  the UI captures the exact target in a system destructive confirmation.

## Models

- [x] Multiple directory scan: versioned security-scoped bookmark envelopes and
  the App-owned model root feed `LocalModelScanner`.
- [x] GGUF metadata is visible: the bounded v2/v3 reader extracts identity,
  architecture, context, tensor, split, quantization, template, and companion
  hints without reading tensor data.
- [x] Hugging Face search and real file list: paginated Hub search/tree clients
  and the catalog classify files from actual tree entries.
- [x] Download, pause, restore/resume, and cancel: persistent
  `ModelDownloadJob` state and production HTTP Range transport have state,
  relaunch, fallback, and mismatch tests.
- [x] Gated token is stored in Keychain: the production Security-framework
  adapter is used by search and download requests, with isolated real-Keychain
  smoke coverage.
- [x] Split GGUF and mmproj grouping: catalog and download-manager tests cover
  complete split groups, companion roles, conflicts, and atomic group import.
- [x] Ordinary files remain Finder-manageable: external models are scanned in
  place, imported Hub artifacts use readable directories, and Reveal in Finder
  is available. Explicit deletion moves exactly one validated GGUF inside an
  approved root to the system Trash; symlinks and owned-server files are
  rejected.

## Profiles

- [x] Multiple Profiles per model: the library creates, selects, duplicates,
  renames, deletes, imports, and exports independent UUID Profiles.
- [x] Readable import/export JSON: `JSONProfileStore` writes one formatted JSON
  document per Profile and avoids overwriting ID collisions.
- [x] Typed fields plus tokenized Extra Arguments: `LaunchProfile` models the
  v1 fields and never stores extra arguments as a shell string.
- [x] Capability warnings: typed controls distinguish supported, unsupported,
  and unknown help detection while retaining unknown extra arguments.
- [x] Command preview equals launched arguments: both come from the same pure
  `ServerInvocationBuilder` result; display quoting is derived only for copy.
- [x] Schema migration is tested: v1-to-v2 migration is atomic and preserves
  unrecognized JSON members.

## Server

- [x] Start, Stop, and Restart are available in the App and backed by the owned
  `ServerProcessController`.
- [x] Health state is adapter-driven: fixtures cover ready, starting,
  unavailable, degraded payloads, early exit, timeout, and cancellation.
- [x] stdout/stderr are timestamped, source-labelled, redacted, and bounded;
  App updates are batched rather than emitted for every line.
- [x] Endpoint, PID, resident memory, CPU, threads, and uptime are shown for the
  owned PID using macOS process APIs.
- [x] Open WebUI and Copy API URL are enabled from the owned run endpoint.
- [x] External processes are not killed: execution uses retained process
  handles and there is no name-based termination path.
- [x] Normal stop leaves no owned orphan: controller tests and the recorded real
  b10176 completion smoke verify PID exit and socket release.

## Release

- [x] Swift tests and unsigned App builds pass: the current suite contains 144
  tests in 39 suites, and CI runs both Core tests and the macOS App build.
- [ ] Developer ID signature and Apple notarization: implementation and
  fail-closed automation exist, but credentials and a successful candidate run
  are still pending.
- [ ] Two-generation Apple Silicon candidate validation: M5 Max / 128 GB
  functional evidence exists; a differently specced earlier generation and
  signed install/Gatekeeper results are pending.
- [x] App update and llama.cpp runtime update are separate in UI, network
  clients, storage, diagnostics, and release policy.
- [x] No plaintext token persistence: credentials use Keychain and redaction
  tests cover headers, token forms, signed URLs, and diagnostics.
- [x] Third-party licensing is present in `THIRD_PARTY_NOTICES.md`; LlamaDock is
  MIT licensed and no third-party source is vendored into the App.

## Remaining delivery gate

The only unchecked design acceptance items require external release authority
or hardware:

1. configure the six Apple signing/notarization Actions secrets;
2. produce a private signed and notarized candidate from the intended `main`
   commit;
3. smoke that exact candidate on two Apple Silicon generations with different
   memory capacities and complete manual accessibility/privacy checks;
4. create `v1.0.0` only after the candidate record is complete, then verify the
   public artifact from a clean account.
