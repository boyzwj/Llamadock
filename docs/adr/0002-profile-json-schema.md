# ADR 0002: Readable versioned Profile JSON

- Status: Accepted
- Date: 2026-07-29

## Context

Profiles must remain readable, copyable, importable, and recoverable without an
opaque database. The `llama-server` flag surface changes frequently, while a
saved Profile may outlive the App version that created it.

## Decision

Each Profile is one UTF-8 JSON file named by its UUID under the App-owned
`profiles` directory. Typed model, runtime, server, and sampling values are
encoded by a declared schema rather than an arbitrary dictionary. Extra
arguments are stored as an array of tokens and are never stored or executed as
a shell command.

Schema changes use explicit monotonically increasing versions. Loading an older
supported document migrates it to the current version through an atomic file
replacement. Unknown JSON members are retained when a document is loaded,
edited, migrated, and saved so that a newer App does not silently destroy
future or extension data. Unsupported future schema versions fail visibly.

Import preserves the source document when possible and assigns a new UUID
instead of overwriting an existing Profile. Export returns the readable JSON
document used by the store.

## Consequences

Profiles can be inspected, backed up, diffed, and moved independently of the
App. Migration and merge behavior require focused tests, and validation must
remain separate from Codable decoding. A field may require a capability warning
when the selected runtime does not advertise its corresponding flag.

## Alternatives

UserDefaults and SQLite were rejected because they make complete Profile
documents less transparent. Storing an entire command string was rejected
because it loses token boundaries and creates shell-quoting and injection risk.
