[![Build status](https://ci.appveyor.com/api/projects/status/4krqni0w1pr1yirl?svg=true)](https://ci.appveyor.com/project/borger/scoop-emulators)
[![Excavator](https://github.com/borger/scoop-emulators/actions/workflows/excavator.yml/badge.svg)](https://github.com/borger/scoop-emulators/actions/workflows/excavator.yml)
[![Repo size](https://img.shields.io/github/repo-size/borger/scoop-emulators.svg)](https://github.com/borger/scoop-emulators)

# Emulators Scoop Bucket

This is a [Scoop](http://scoop.sh) bucket for emulators. It's focused on Windows emulators and core tooling. Interested in adding something? See our [contribution guide](#contributing) before working on a pull request.

This bucket is curated and not intended to be a catch-all. All emulators in this bucket are maintained, have active development, and have a strong active user-base. For other emulators, games, and other apps, check out [scoop-games](https://github.com/Calinou/scoop-games) or other scoop buckets.

## 1. (Prerequisite) Installing Scoop

Windows 10 and Windows 11 include PowerShell installed by default. Open the start menu and type `PowerShell`. You might see both `Windows PowerShell` and [PowerShell 7 (x64)](https://docs.microsoft.com/en-us/PowerShell/scripting/install/installing-PowerShell), the latter is recommended, but the former works too.
Scoop and apps will be installed by default in the user home folder. `~/scoop` aka `%HOMEDRIVE%%HOMEPATH%\scoop` aka `C:\Users\<username>\scoop\`

Install Scoop by executing the following command in PowerShell (start > PowerShell):

```
iwr -useb get.scoop.sh | iex
```

## 2. Adding Emulators Bucket to Scoop

To use this bucket, you must have [scoop](#1-prerequisite-installing-scoop) installed first.
To add this bucket to scoop, run

```
scoop bucket add emulators https://github.com/borger/scoop-emulators.git
```

The bucket will be installed at `~/scoop/buckets/emulators/` aka `%HOMEDRIVE%%HOMEPATH%\scoop\buckets\emulators\` aka `C:\Users\<username>\scoop\buckets\emulators\`.

To see what apps are available to install (from all added buckets), run

```
scoop search
```

## 3. Installing Emulators using Scoop

The emulators will be installed at `~/scoop/apps/<app-name>/current`. For each installed emulator, the app config and data persist across your installs/updates. This is managed by [Scoop](http://scoop.sh). Shortcuts will be automatically created on your start menu.

With the emulators' scoop bucket installed, run

```
scoop install <app-name>
# examples:
scoop install retroarch
scoop install citra-canary yuzu mesen
```

### Notes on the Install Path

There's no way to specify a custom install folder per installed app in [Scoop](http://scoop.sh), there is however an alternative solution. You can create a [Junction](https://www.geeksforgeeks.org/ntfs-junction-points/) which creates a link to a custom install location.

To create a symlink, run the command in command prompt (start > cmd). You can also switch to cmd from PowerShell by running `cmd`. You may need to run cmd as an administrator.

```
mklink /D "<destination-path>" "%HOMEDRIVE%%HOMEPATH%\scoop\apps\<app-name>\current"
```

### List of Emulators

Each file listed in the [bucket folder](https://github.com/borger/scoop-emulators/tree/master/bucket) is an app available to install.

## 4. Updates

This bucket checks for updates every hour to ensure it stays updated with the latest releases from all our favorite emulators. However, its up to you to run the scoop update commands in order to update.

### 4a. Updating Scoop and bucket metadata

To update scoop metadata, run

```
    scoop update
```

### 4b. Updating Emulators from the Scoop Bucket

To update all the apps installed via [Scoop](http://scoop.sh), run

```
scoop update *
```

To update a specific emulator via scoop, run

```
scoop update <app-name>
# examples:
scoop update retroarch
scoop update citra-canary mesen
```

### 4c. Automating Updates

Create a PowerShell script and add it to Windows' Task Scheduler or add multiple "start a program" actions to run daily or in your preferred schedule. The script contents would just be:

```
scoop update
scoop update *
```

## Contributing

Thank you for considering contributing to the Emulators Scoop Bucket! You may propose new features or improvements of existing bucket behavior in the GitHub issue board. If you propose a new feature, please be willing to implement at least some of the code that would be needed to complete the feature.

### Requirements for adding a new emulator to the bucket

- Active development - Is there recent commit activity in the past 2 years?
- Recent releases - Is there a recent stable release in the past 3 years?
- Does it work on Windows 10 and Windows 11?
- Does it have a portable mode setting where appdata is stored in the same folder as the app?
- Does it have a strong user base and broad appeal?

If you answered NO to any of the preceding questions, it most likely isn't a good fit for this bucket. But don't worry, there are plenty of other buckets out there that might fit better, you'll have to do some research.

### Creating a manifest (adding an app to scoop)

A scoop [app manifest](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests) is a json file that is used to tell scoop how to install/update/uninstall an app. We recommend reading the documentation on [creating an app manifest](https://github.com/ScoopInstaller/Scoop/wiki/Creating-an-app-manifest).

Are you able to create a complete full featured manifest to add the app you want to the bucket? Will you fix the manifest in a timely manner when it eventually breaks due to changes out of our control?

If you answered yes, you can get started by copying a manifest that is similar to the app you want to add. You will need to go to the app's github or homepage and gather info needed to edit the manifest.

If you answered NO to either question, please gather information that will be needed before filling submitting an issue and follow the template.

### PR Checklist

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

## Credits

- [lukesampson](https://github.com/lukesampson) for creating Scoop and the original Retroarch manifest.
- [hermanjustnu](https://github.com/hermanjustnu/) for the original scoop-emulator repo.
- [Ash258](https://github.com/Ash258) for creating the original RPCS3 manifest.
- [Calinou](https://github.com/Calinou) for creating the scoop-games repository.
- [beyondmeat](https://github.com/beyondmeat) for helping add more emulators to this bucket, fixing various bugs, and maintaining manifests.
