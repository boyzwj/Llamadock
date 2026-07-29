# ADR 0003: Managed runtime installation transaction

- Status: Accepted
- Date: 2026-07-29

## Context

LlamaDock installs frequently changing upstream `llama.cpp` archives. A failed,
malformed, or interrupted install must not damage the active runtime or write
outside the app-owned runtime directory.

## Decision

Each install uses a unique directory under `runtimes/downloads`. The archive is
downloaded as `asset.part`, checked against the GitHub asset size and available
SHA-256 digest, and inspected before extraction. Absolute paths, parent
traversal, excessive depth, and escaping link targets are rejected.

The system archive tool is invoked only by absolute executable URL and argument
array. It extracts into the unique transaction directory; extracted links are
checked again before binary validation.

Only after archive, binary, and architecture validation succeeds may the
prepared directory be atomically moved into its build directory and registered.
Registry replacement and active-runtime selection are separate atomic writes.
Failure before registration leaves active and previous unchanged.

## Consequences

Incomplete downloads and extraction trees are never runtime candidates.
Install failures remain diagnosable and retryable. The installer needs explicit
cleanup, archive inspection, checksum, binary validation, and registry
abstractions that can be replaced by fakes in tests.

## Alternatives

Extracting directly into the final build directory was rejected because partial
contents could appear installed. Trusting archive-tool defaults alone was
rejected because path and link safety would be implicit and difficult to test.
