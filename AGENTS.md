# LlamaDock Agent Instructions

## Version iteration completion

- A version iteration is not complete when the code change alone is finished.
- After the final source change and required tests pass, rebuild the app from the latest workspace state using the Release configuration, create a fresh local package, and reinstall that build at `/Applications/Llamadock.app`.
- Never reuse an older build artifact for this step. Verify the installed app's version/build metadata and code signature after copying it.
- If packaging or local installation cannot be completed, report the iteration as incomplete and state the blocking reason explicitly.
