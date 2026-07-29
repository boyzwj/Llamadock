# Third-Party Notices

LlamaDock vendors no third-party source code or binary artifacts in its app
bundle.

## llama.cpp

LlamaDock can download official release archives from
[`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp) or launch an
installation selected by the user. `llama.cpp` is not linked into or bundled
with LlamaDock. Managed runtime files remain separate in LlamaDock's application
support directory. Upstream is licensed under the MIT License; each downloaded
archive contains its upstream license files.

## Hugging Face models

LlamaDock can download model files the user selects from Hugging Face. Models
are not part of the LlamaDock distribution. Their licenses and usage terms are
set by their respective repository owners and remain visible on the repository
release page.

Any future bundled dependency or copied source must be added here with its exact
upstream project, revision, and license before release.
