# Contributing

You may propose new features or improvements by filing an issue. If you propose a new emulator, you will need to create the manifest file and complete the checklist provided in the template.

## Requirements for adding a new emulator to the bucket

- Active development - Is there recent commit activity in the past 2 years?
- Recent releases - Is there a recent stable release in the past 3 years?
- Does it work on Windows 10 and Windows 11?
- Does it have a portable mode setting where appdata is stored in the same folder as the app?
- Does it have a strong user base and broad appeal?

If you answered NO to any of the preceding questions, it most likely isn't a good fit for this bucket. But don't worry, there are plenty of other buckets out there that might fit better, you'll have to do some research.

## Creating a manifest (adding an app to scoop)

A scoop [app manifest](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests) is a json file that is used to tell scoop how to install/update/uninstall an app. We recommend reading the documentation on [creating an app manifest](https://github.com/ScoopInstaller/Scoop/wiki/Creating-an-app-manifest).

Are you able to create a complete full featured manifest to add the app you want to the bucket? Will you fix the manifest in a timely manner when it eventually breaks due to changes out of our control?

If you answered yes, you can get started by copying a manifest that is similar to the app you want to add. You will need to go to the app's github or homepage and gather info needed to edit the manifest.

If you answered NO to either question, please gather information that will be needed before filling submitting an issue and follow the template.

## PR Checklist

You will need to complete a PR checklist and ensure your manifest meets our minimum required standards to be considered.

- does it have properly named and capitalized shortcuts?
- does it have a autoupdate entry?
- does it have a checkver entry? [](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifest-Autoupdate)
- does it have [persist](https://github.com/ScoopInstaller/Scoop/wiki/Persistent-data) defined with config/data/user/portable/textures/saves folder(s) specific for the app?
- does it have a [pre_install](https://github.com/ScoopInstaller/Scoop/wiki/Pre--and-Post-install-scripts) script to auto-enable portable mode (if needed)?
- does it have a license url?
- does it have a description, is it in the same format as the others?
- does it have bin entries
  - if beta, dev, nightly, canary, etc: does bin have rewrite with variant appended.
- does it pass `bin/checkver.ps1` and `bin/checkurls.ps1`?
- does it have a version?
- does it have a url to the release along with its sha256 hash?

