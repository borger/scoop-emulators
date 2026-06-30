# Installing and Using Scoop Emulators

## 1. Installing Scoop

Windows 10 and Windows 11 include PowerShell installed by default. Open the start menu and type `PowerShell`. You might see both `Windows PowerShell` and [PowerShell 7 (x64)](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell), the latter is recommended, but the former works too.

Open PowerShell and run:

```powershell
iwr -useb get.scoop.sh | iex
```

Scoop installs to `~/scoop` (e.g., `C:\Users\<username>\scoop\`)

## 2. Adding This Bucket

```powershell
scoop bucket add emulators https://github.com/borger/scoop-emulators.git
```

To search for available apps across all added buckets, run:

```powershell
scoop search
```

## 3. Installing Emulators

```powershell
scoop install <app-name>
# examples:
scoop install retroarch
scoop install mame scummvm ares
```

Apps install to `~/scoop/apps/<app-name>/current`. Config and data persist across installs/updates and shortcuts are auto-created in the Start menu.

**Custom Install Location:** There's no way to specify a custom install folder per app in Scoop, but you can create a [Symbolic Link](https://www.howtogeek.com/16226/complete-guide-to-symbolic-links-symlinks-on-windows-or-linux/) to link to a custom location. Run in Command Prompt as Administrator:

```cmd
mklink /D "C:\custom\path" "%HOMEDRIVE%%HOMEPATH%\scoop\apps\<app-name>\current"
```

## 4. Updates

This bucket checks for updates every hour via GitHub actions. You must run update commands manually locally to apply them:

```powershell
scoop update              # Update metadata
scoop update *            # Update all installed apps
scoop update <app-name>   # Update a specific app
```

**Automating Updates:** Create a `scoop-update.ps1` script with:

```powershell
scoop update
scoop update *
```

Then add it to Windows Task Scheduler, or register it via PowerShell (run as Administrator):

```powershell
$taskName = "Scoop Update"
$scriptPath = "$env:USERPROFILE\scoop-update.ps1"
$trigger = New-ScheduledTaskTrigger -Daily -At 8am
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
Register-ScheduledTask -TaskName $taskName -Trigger $trigger -Action $action -RunLevel Highest
```
