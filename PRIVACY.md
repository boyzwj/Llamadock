# LlamaDock Privacy

LlamaDock is a local macOS control plane for `llama.cpp`. It has no analytics,
advertising, telemetry, account system, or LlamaDock-operated cloud service.

## Data stored on the Mac

LlamaDock stores readable settings, runtime records, download state, and launch
Profiles under `~/Library/Application Support/Llamadock/`. Profiles may contain
model paths and server options. Hugging Face access tokens are stored only as a
generic password in macOS Keychain, not in JSON, UserDefaults, diagnostics, or
logs.

Server output is kept in a bounded in-memory buffer. LlamaDock diagnostics
include versions, hardware capacity, counts, state summaries, endpoints, and
redacted errors. They deliberately exclude credentials, signed URL queries,
prompts, launch arguments, and server log contents. Diagnostics leave the Mac
only when the user explicitly copies and shares them.

## Network connections

LlamaDock connects only when needed for a user-visible feature:

- GitHub API and release assets for LlamaDock app update checks and managed
  `llama.cpp` runtime releases;
- Hugging Face APIs and file hosts for model search and downloads;
- the locally configured `llama-server` endpoint for health and API readiness.

A Hugging Face token is attached only to eligible Hub requests. Authorization
is removed on cross-host redirects, and signed download query strings are
redacted from diagnostics and logs.

## Files and processes

LlamaDock accesses its own application-support directory and model directories
the user explicitly selects. It launches and stops only process handles it
created; it does not use process-name-wide termination. External runtimes and
models remain user-owned.

## Deletion

Removing the Hugging Face token deletes its Keychain item. Other LlamaDock data
can be removed by deleting `~/Library/Application Support/Llamadock/` after
stopping the app and any server it owns. Models in external user-selected
directories are not deleted by that action. When the user explicitly chooses
**Move to Trash** for one library entry, LlamaDock validates that the target is
a regular GGUF file inside an approved model root and asks for confirmation
before moving only that file to the macOS Trash. It does not follow symlinks,
delete the containing folder, or delete a model or companion used by its
running server.

## Contact

Privacy and security issues can be reported through the repository:
<https://github.com/boyzwj/Llamadock/issues>.
