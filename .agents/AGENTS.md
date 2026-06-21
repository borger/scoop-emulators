# Project Rules

- **Testing Manifests**: When testing, verifying, or validating Scoop manifests, always use the helper scripts located in the `bin` directory of the workspace, such as:
  - `bin/check-manifest-install.ps1` to test installation and verification of a manifest.
  - `bin/checkver.ps1` to test checkver update patterns.
  - `bin/test.ps1` to run general Pester tests for the bucket.

- **Checkver & Autoupdate Guidelines**:
  - When the GitHub release tags use custom text prefixes (e.g., `Goldeneye1.2.4`), prefer defining the `autoupdate` URL using a template like `Goldeneye$version` rather than capturing `$matchTag` if possible. This is because local test scripts like `check-manifest-install.ps1` only perform simple substitution on `$version` to validate URL endpoints, and using `$matchTag` will trigger false positive 404 test failures.
  - For projects that are ports or recompilations (e.g. recomp projects), archive structures (like folder naming inside `.zip` or `.rar`) and binary executable names might change between releases. Always extract and verify the actual filenames/directory tree of the latest asset to update `extract_dir` and the `bin` entry accordingly.
