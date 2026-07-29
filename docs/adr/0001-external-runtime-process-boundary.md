# ADR 0001: External runtime process boundary

- Status: Accepted
- Date: 2026-07-29

## Context

LlamaDock must allow `llama.cpp` to upgrade independently from the app and must
keep inference crashes outside the SwiftUI process.

## Decision

LlamaDock will not link `libllama` or an XCFramework. It will launch an absolute
`llama` or `llama-server` executable URL with Foundation `Process`.

## Consequences

Runtime upgrades and failures are isolated from the app. LlamaDock must own
subprocess lifecycle, capability probing, logs, and HTTP readiness.

## Alternatives

Linking `llama.cpp` directly was rejected because it couples app releases and
inference runtime releases.
