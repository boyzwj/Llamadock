# ADR 0005: Non-sandboxed v1 distribution boundary

- Status: Accepted
- Date: 2026-07-29
- Extended by: ADR 0007

## Context

LlamaDock launches user-selected and App-managed executables and works with
large model directories selected by the user. The design requires an explicit
App Sandbox decision before release so that file access and process ownership
are not reworked late in the project.

## Decision

LlamaDock v1 is distributed without App Sandbox. It still uses user selection,
security-scoped bookmark envelopes, canonical-path validation, and strict
App-owned directory checks to bound file access. It launches only absolute
executable URLs, owns only the child processes it creates, and never modifies
shell initialization or kills processes by name.

Public artifacts require Developer ID Application signing, Hardened Runtime,
Apple notarization, a stapled ticket, and successful Gatekeeper assessment.
ADR 0007 defines the complete release and App-update boundary.

## Consequences

The v1 process boundary remains compatible with external `llama.cpp`
executables and transparent model folders. The App is not eligible for Mac App
Store distribution in this form. Non-sandboxed operation does not grant
permission to scan arbitrary user files; UI selection and validated ownership
remain product invariants.

Enabling App Sandbox later requires a new ADR and signed experiments covering
external executable launch, bookmark restoration, downloads, update helpers,
and migration of existing settings.

## Alternatives

Enabling App Sandbox for v1 was deferred because external executable launch and
distribution behavior need a dedicated signed qualification matrix. Omitting
both sandboxing and explicit path/process boundaries was rejected as unsafe.
