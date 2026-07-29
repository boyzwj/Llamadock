# ADR 0007: Release security and update boundary

- Status: Accepted
- Date: 2026-07-29

## Context

LlamaDock must launch user-selected and app-managed `llama-server` executables,
read models outside its own container through user-approved bookmarks, and ship
as a normal macOS application. App updates and `llama.cpp` runtime updates have
different publishers, cadences, trust boundaries, and rollback behavior.

The project design permits a non-sandboxed release if the choice is explicit
and the app still uses Developer ID signing, Hardened Runtime, notarization, and
strict path/process ownership checks. It also says Sparkle may be added after
the MVP rather than becoming a prerequisite for the first release.

## Decision

The v1 release is explicitly non-sandboxed (`ENABLE_APP_SANDBOX = NO`) and uses
Hardened Runtime. Distribution must be signed with a Developer ID Application
identity and notarized by Apple before a public GitHub Release is published.

LlamaDock v1 checks only this repository's GitHub `releases/latest` endpoint for
app updates. When a newer semantic version exists, the app presents the HTTPS
GitHub release page for an explicit user download. It never replaces itself in
the background. A later Sparkle integration requires a separate ADR covering
appcast hosting, EdDSA key custody, downgrade behavior, and helper-service
signing.

The app update channel is separate from managed `llama.cpp` updates:

- LlamaDock app releases come from `boyzwj/Llamadock`;
- managed runtime releases come from `ggml-org/llama.cpp`;
- neither update channel silently activates the other;
- the UI names both products and actions explicitly.

Release artifacts are ZIP files accompanied by `SHA256SUMS`. Signing,
notarization, stapling, archive validation, tests, and a real-runtime smoke test
are automated gates. No certificate, notary credential, or update secret is
stored in the repository.

## Consequences

- External runtime execution remains compatible with the existing process
  boundary and model bookmarks.
- The release cannot be represented as production-ready until Developer ID and
  notarization gates pass.
- App updates require an explicit user download in v1; there is no silent
  background installation.
- Adding App Sandbox or an automatic updater later requires focused migration
  work and a new ADR.
