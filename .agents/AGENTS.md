# Scoop Emulators Bucket - AI Instructions

## Manifest changes

- When adding or removing a manifest, update its entry in the `README.md` emulator tables.
- Verify manifest details, especially the license, against an authoritative project source. Include `license`; use a Scoop license object when needed.
- Add `autoupdate` and `persist` whenever supported and verifiable. Do not guess; note why either is omitted.
- Before finalizing a new manifest, install it, launch the installed executable, and monitor for created or changed files and folders. Add app-relative user data, configuration, and save paths to `persist`. If you cannot run the app, report that the check is incomplete.
- Use the repository helpers to validate manifests:
  - `.\bin\checkver.ps1 -Dir bucket -App appname`
  - `.\bin\check-autoupdate.ps1 -ManifestPath bucket\app.json`
  - `.\bin\check-manifest-install.ps1 -ManifestPath bucket\app.json`
  - `.\bin\checkurls.ps1 -ManifestPath bucket\app.json`
- Keep `checkver` and `autoupdate` version formats consistent. Verify archive contents and executable paths before setting `extract_dir` or `bin`.

## Script changes

- Keep scripts compatible with Windows PowerShell 5.1. Parse-check changed scripts with its AST parser and run relevant tests; use `.\Scoop-Bucket.Tests.ps1` for script changes.
- Write files as UTF-8 without BOM and avoid trailing whitespace. Guard access to optional nested manifest fields before reading or writing them.
