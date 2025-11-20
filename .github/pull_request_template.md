<!-- Provide a general summary of your changes in the title above -->

<!--
  By opening this PR you confirm that you will follow the contribution guidelines.
  You agree to submit a fully featured working manifest that creates shortcuts,
  bin shims, persists data, enables portable mode, and has auto-update support.
-->

- [ ] I have read the [Contributing Guide](../CONTRIBUTING.md).

## What emulator release type is this?
- [ ] stable
- [ ] beta/preview
- [ ] canary/dev
- [ ] nightly

## My manifest has these required entries:
- [ ] [name, description, homepage, and license](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests#required-properties)
- [ ] [autoupdate and checkver](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifest-Autoupdate)
- [ ] [persist](https://github.com/ScoopInstaller/Scoop/wiki/Persistent-data)

## Manifest Validation

All manifests are automatically validated. These checks must pass:

- [ ] `checkver` script detects latest version correctly
- [ ] `autoupdate` configuration is valid
- [ ] Manifest installs successfully on Windows 10/11

**Note**: Validation runs automatically on all PRs. If you want to test locally:
```powershell
.\bin\checkver.ps1 <app-name>
.\bin\check-autoupdate.ps1 bucket/<app-name>.json
.\bin\check-manifest-install.ps1 bucket/<app-name>.json
```

## Portability Checklist
- [ ] Is this emulator portable by default?
  - [ ] Yes
  - [ ] No, but I added a `pre_install` script that enables it automatically
- [ ] Is this a non-stable version?
  - [ ] No
  - [ ] Yes, I added separate `bin` and `shortcut` entries (see [citra-canary](https://github.com/borger/scoop-emulators/blob/master/bucket/citra-canary.json) for an example)

## PR Process

After submitting:
1. Automated validation scripts will run
2. If all validations pass: @beyondmeat will be tagged for review
3. If any validation fails: You'll receive feedback with specific errors
4. For Copilot-generated PRs: Auto-merge happens automatically on success

See [AI_INSTRUCTIONS.md](../AI_INSTRUCTIONS.md) for workflow details.
