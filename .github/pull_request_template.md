<!-- Provide a general summary of your changes in the title above -->

<!--
  By opening this PR you confirm that will follow the contribution guidelines. You agree to submit a fully featured working manifest that creates shortcuts, bin shims, persists data, enable portable mode, and auto updates.
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

## Checklist
- [ ] Is this emulator is portable by default (without a file / setting change needed)?
  - [ ] Yes
  - [ ] No, but I added a [pre_install](https://github.com/ScoopInstaller/Scoop/wiki/Pre--and-Post-install-scripts) script that enables it automatically during install
- [ ] Is this a non-stable version of the emulator?
  - [ ] No
  - [ ] Yes, I added the [bin and shortcut](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests#optional-properties) entries (see [citra-canary](https://github.com/borger/scoop-emulators/blob/master/bucket/citra-canary.json) for an example on what to do)
