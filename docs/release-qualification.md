# LlamaDock v1 release qualification

This record must contain real results. Do not mark a row passed from simulated
or inferred evidence.

## Candidate

- Version: `1.0.0`
- Build: `1`
- Git commit: pending (record the exact qualified `main` SHA)
- Git tag: pending (create `v1.0.0` only after candidate qualification)
- GitHub Actions release candidate run: pending
- GitHub Actions release run: pending
- ZIP SHA-256: pending
- Notarization submission ID: pending

## Automated gates

- [x] 146 Core tests pass.
- [x] Debug and unsigned arm64 Release App builds pass.
- [x] Release-contract verification passes.
- [ ] Developer ID signature and Hardened Runtime verified.
- [ ] Apple notarization status is `Accepted`.
- [ ] Stapler validation passes.
- [ ] Gatekeeper assessment passes.
- [ ] Published ZIP and dSYM SHA-256 files verify.

## Apple Silicon smoke matrix

| Hardware | Memory | macOS | Install / Gatekeeper | Runtime discovery / install | Model import / HF download | Profile restore | Start / completion / stop | No owned orphan | Result |
|---|---:|---|---|---|---|---|---|---|---|
| Apple M5 Max, `Mac17,6` | 128 GB | 27.0 (`26A5388g`) | Unsigned candidate builds; signed install and Gatekeeper pending | Prior real UI b10176 install plus current b10176 direct smoke | Prior production HF delivery smoke; model SHA verified below | Prior relaunch qualification | Pass | Pass | Partial: functional pass, signed artifact pending |
| Generation 2: pending | pending | pending | pending | pending | pending | pending | pending | pending | pending |

For each row, attach the machine model identifier, chip, exact memory, macOS
build, runtime build, GGUF identity and SHA-256, start-to-ready time, completion
result, stopped PID/socket evidence, and tester/date.

### `Mac17,6` evidence

- Date: 2026-07-29 (Asia/Shanghai).
- Candidate commit: `1ce3eae9696589eec930981694ee0aa650ecf1dd`.
- Hardware: MacBook Pro `Mac17,6`, Apple M5 Max, 18 CPU cores,
  128 GB memory.
- Software: macOS 27.0 build `26A5388g`; Xcode 26.6 build `17F113`;
  Swift 6.3.3.
- Runtime: official `llama.cpp` b10176 revision `f5b9bd39b`, Darwin
  arm64.
- Model: `ggml-org/tiny-llamas/stories15M-q4_0.gguf`, 19,077,344
  bytes, SHA-256
  `6151b1929d7f5aa3385d9ddef3393e55587c0a55de661562322bc51dfda93a04`.
- Smoke: `Scripts/smoke-real-runtime.sh` passed `/health`, `/v1/models`,
  and `/v1/completions` at `127.0.0.1:18084`; the script then verified
  the owned PID no longer existed and the socket was released.
- Release build: unsigned validation-only arm64 Release build passed and
  contained `AppIcon.icns`, `Assets.car`, version `1.0.0 (1)`.
- Limitation: no Developer ID identity or notarization secrets are
  available in the current environment, so signed install, stapling,
  Gatekeeper, and published ZIP checks remain pending.

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
