# ADR 0006: No shell process execution

- Status: Accepted
- Date: 2026-07-29

## Context

Runtime paths, model paths, and profile arguments can contain user-controlled
text. Building shell commands would introduce quoting errors and injection risk.

## Decision

Every subprocess receives an absolute executable URL and an argument array.
LlamaDock never routes user input through `/bin/zsh -c` or another shell.
Display commands are derived output and are never used for execution.

## Consequences

Command construction must be typed and testable. Features that rely on shell
initialization or implicit `PATH` lookup are unavailable by design.

## Alternatives

Shell command strings were rejected because their convenience does not justify
the security and reproducibility costs.
