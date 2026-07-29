# ADR 0004: User-approved model directories and bookmarks

- Status: Accepted
- Date: 2026-07-29

## Context

Users must be able to keep GGUF files in ordinary directories outside
LlamaDock's Application Support folder. Persisting only a path is insufficient
when macOS access grants or files move, and scanning must not escape the
directory the user selected.

## Decision

External model roots are chosen through the system Open Panel and persisted as
versioned security-scoped bookmark envelopes. On restore, LlamaDock resolves
the bookmark, refreshes stale bookmark data, and keeps resolution failures
visible rather than silently dropping a root. A still-readable original path
may be used to recover an obsolete bookmark and write a new envelope.

Scanning starts access only for the bounded operation and balances every
successful `startAccessingSecurityScopedResource` call. Server runs retain the
minimum required model and companion scopes until that owned process stops.
Resolved URLs must remain within the approved root; scans do not follow links
that escape it. The App-owned models directory is also represented as a normal,
transparent root but does not require a user bookmark.

## Consequences

Model files remain user-owned and Finder-manageable. Relaunch can restore
authorized roots without assuming the GUI App inherits Terminal permissions.
Broken, stale, duplicate, and insecure bookmarks require explicit data models,
diagnostics, and tests.

## Alternatives

Copying every imported GGUF into a private blob store was rejected because it
breaks file transparency and duplicates large files. Persisting raw paths alone
was rejected because it does not preserve macOS access decisions.
