# LlamaDock v1 release qualification

This record must contain real results. Do not mark a row passed from simulated
or inferred evidence.

## Candidate

- Version: `1.0.0`
- Build: `1`
- Git commit: pending
- Git tag: `v1.0.0`
- GitHub Actions release run: pending
- ZIP SHA-256: pending
- Notarization submission ID: pending

## Automated gates

- [ ] 132 Core tests pass.
- [ ] Debug and Release App builds pass.
- [ ] Release-contract verification passes.
- [ ] Developer ID signature and Hardened Runtime verified.
- [ ] Apple notarization status is `Accepted`.
- [ ] Stapler validation passes.
- [ ] Gatekeeper assessment passes.
- [ ] Published ZIP and dSYM SHA-256 files verify.

## Apple Silicon smoke matrix

| Hardware | Memory | macOS | Install / Gatekeeper | Runtime discovery / install | Model import / HF download | Profile restore | Start / completion / stop | No owned orphan | Result |
|---|---:|---|---|---|---|---|---|---|---|
| Generation 1: pending | pending | pending | pending | pending | pending | pending | pending | pending | pending |
| Generation 2: pending | pending | pending | pending | pending | pending | pending | pending | pending | pending |

For each row, attach the machine model identifier, chip, exact memory, macOS
build, runtime build, GGUF identity and SHA-256, start-to-ready time, completion
result, stopped PID/socket evidence, and tester/date.

## Manual accessibility and privacy checks

- [ ] Keyboard navigation reaches primary sidebar, toolbar, forms, download
  controls, server controls, and Settings.
- [ ] VoiceOver announces server state, progress, metrics, and log region.
- [ ] Status is expressed by text/icon as well as color.
- [ ] Light and dark appearances remain legible.
- [ ] Copied diagnostics contain no token, prompt, launch argument, or log
  contents.
- [ ] Keychain item is removed when the token is cleared.
- [ ] Privacy and third-party notices are accessible from the repository and
  release notes.

## Sign-off

- Engineering: pending
- Release owner: pending
- Date: pending
