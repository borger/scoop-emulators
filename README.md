[![Tests](https://github.com/borger/scoop-emulators/actions/workflows/ci.yml/badge.svg)](https://github.com/borger/scoop-emulators/actions/workflows/ci.yml)
[![Excavator](https://github.com/borger/scoop-emulators/actions/workflows/excavator.yml/badge.svg)](https://github.com/borger/scoop-emulators/actions/workflows/excavator.yml)
[![Repo size](https://img.shields.io/github/repo-size/borger/scoop-emulators.svg)](https://github.com/borger/scoop-emulators)

# Emulators Scoop Bucket

This is a [Scoop](http://scoop.sh) bucket for emulators. It's focused on Windows emulators and core tooling.

This bucket is curated and not intended to be a catch-all. All emulators in this bucket are maintained, have active development, and have a strong active user-base. For other emulators, games, and other apps, check out [scoop-games](https://github.com/Calinou/scoop-games) or other scoop buckets.

Interested in adding something? To add a new emulator, please read the [Contributing Guide](./CONTRIBUTING.md).

## 1. Installing Scoop

Open PowerShell (Windows 10/11 have it built-in) and run:
```powershell
iwr -useb get.scoop.sh | iex
```

Scoop installs to `~/scoop` (e.g., `C:\Users\<username>\scoop\`)

## 2. Adding This Bucket

```powershell
scoop bucket add emulators https://github.com/borger/scoop-emulators.git
scoop search               # View available apps
```

## 3. Installing Emulators

```powershell
scoop install mame scummvm ares
```

Apps install to `~/scoop/apps/<app-name>/current`. Config and shortcuts are auto-managed by Scoop.

**Custom Install Location:** Use junctions to link apps to custom folders:
```cmd
mklink /D "C:\custom\path" "%HOMEDRIVE%%HOMEPATH%\scoop\apps\<app-name>\current"
```

## 4. Updates

**Bucket auto-checks hourly for updates.** You must run update commands manually:

```powershell
scoop update              # Update metadata
scoop update *            # Update all installed apps
scoop update <app-name>   # Update specific app
```

**Automate with Task Scheduler:**

Create `scoop-update.ps1` with:
```powershell
scoop update
scoop update *
```

Then register the task (run as Administrator):
```powershell
$taskName = "Scoop Update"
$scriptPath = "$env:USERPROFILE\scoop-update.ps1"
$trigger = New-ScheduledTaskTrigger -Daily -At 8am
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -RunLevel Highest
```

---

## Credits

- [beyondmeat](https://github.com/beyondmeat) - main contributor and maintainer of this bucket.
