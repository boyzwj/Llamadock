# LlamaDock release guide

LlamaDock v1 targets Apple Silicon Macs running macOS 14 or later. Public
artifacts must be signed with Developer ID Application, use Hardened Runtime,
be accepted by Apple notarization, have the ticket stapled, and pass
Gatekeeper assessment. The release workflow intentionally fails before
publishing if any of those checks fails.

## Repository secrets

Configure these GitHub Actions secrets:

- `APPLE_CERTIFICATE_BASE64`: Base64-encoded Developer ID Application `.p12`.
- `APPLE_CERTIFICATE_PASSWORD`: Password used when exporting the `.p12`.
- `APPLE_SIGNING_IDENTITY`: Full `Developer ID Application: ... (TEAMID)`
  identity.
- `APPLE_TEAM_ID`: Apple Developer Team ID.
- `APPLE_ID`: Apple ID used for notarization.
- `APPLE_APP_SPECIFIC_PASSWORD`: App-specific password for notarization.

The workflow imports the certificate and notarization profile into an
ephemeral keychain and removes that keychain at the end. It never creates or
uploads an unsigned fallback artifact.

## Release procedure

1. Merge a clean Milestone 5 pull request after Core, App, and release-contract
   checks pass.
2. Run the `Release` workflow manually from the intended main commit and enter
   its semantic `expected_version`. Manual mode signs, notarizes, staples, and
   verifies the candidate with the production pipeline, then uploads a private
   seven-day GitHub Actions artifact. It never creates a GitHub Release.
3. Download the signed candidate and matching SHA-256 file from the workflow.
   Verify and smoke it on at least two Apple Silicon generations with different
   memory capacities. Record the real evidence in
   `docs/release-qualification.md`.
4. Confirm `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, release notes,
   privacy documentation, licenses, and the qualification record.
5. Create and push an annotated tag on the qualified commit matching the app
   version, for example
   `v1.0.0`.
6. Wait for the `Release` workflow. It rebuilds and tests from the tag, imports
   signing credentials, creates an arm64 archive, verifies Developer ID and
   Hardened Runtime, notarizes, staples, checks Gatekeeper, creates ZIP and
   dSYM archives, verifies SHA-256 files, and only then creates the GitHub
   Release.
7. Download the published ZIP on a clean test account, verify its SHA-256,
   launch it through Finder, and repeat the core start/completion/stop smoke.

Do not create a public GitHub Release manually from a local unsigned build.

## Local signed packaging

After creating a validated `notarytool` Keychain profile:

```bash
SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)' \
DEVELOPMENT_TEAM='TEAMID' \
NOTARY_KEYCHAIN_PROFILE='llamadock-release' \
RELEASE_TAG='v1.0.0' \
Scripts/package-release.sh
```

The generated files are written to `dist/release/`, which is intentionally
ignored by Git.

## Rollback

GitHub Releases are immutable inputs to the app update checker but do not
replace users' managed `llama.cpp` runtimes. If a LlamaDock release is bad,
mark it as a prerelease or delete only that GitHub Release, fix forward on a
new patch version/build, and publish a new signed and notarized tag. Never
replace an existing ZIP under the same tag.
