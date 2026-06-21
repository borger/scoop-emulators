# Project Rules

- **Testing Manifests**: When testing, verifying, or validating Scoop manifests, always use the helper scripts located in the `bin` directory of the workspace, such as:
  - `bin/check-manifest-install.ps1` to test installation and verification of a manifest.
  - `bin/checkver.ps1` to test checkver update patterns.
  - `bin/test.ps1` to run general Pester tests for the bucket.
