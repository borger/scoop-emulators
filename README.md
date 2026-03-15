[![Tests](https://github.com/borger/scoop-emulators/actions/workflows/ci.yml/badge.svg)](https://github.com/borger/scoop-emulators/actions/workflows/ci.yml)
[![Excavator](https://github.com/borger/scoop-emulators/actions/workflows/excavator.yml/badge.svg)](https://github.com/borger/scoop-emulators/actions/workflows/excavator.yml)
[![Repo size](https://img.shields.io/github/repo-size/borger/scoop-emulators.svg)](https://github.com/borger/scoop-emulators)
[![License](https://img.shields.io/github/license/borger/scoop-emulators.svg)](https://github.com/borger/scoop-emulators/blob/master/LICENSE)

# Emulators Scoop Bucket

This is a [Scoop](https://scoop.sh) bucket for emulators. It's focused on Windows emulators and core tooling.

This bucket is curated and not intended to be a catch-all. All emulators in this bucket are maintained, have active development, and have a strong active user-base. For other emulators, games, and other apps, check out [scoop-games](https://github.com/Calinou/scoop-games) or other scoop buckets.

Interested in adding something? To add a new emulator, please read the [Contributing Guide](./CONTRIBUTING.md).

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

## Available Emulators

Dev/nightly variants (e.g. `dolphin-dev`) track unstable builds and are listed under the same entry.

### Multi-system

| App | Systems | Variants | Homepage |
|-----|---------|----------|----------|
| `ares` | Multi-system | — | [ares-emu.net](https://ares-emu.net) |
| `mame` | Arcade & more | — | [mamedev.org](https://www.mamedev.org) |
| `mednafen` | Multi-system | `dev` | [mednafen.github.io](https://mednafen.github.io/) |
| `retroarch` | Multi-system frontend | `nightly` | [retroarch.com](https://www.retroarch.com/) |

### Nintendo

| App | Systems | Variants | Homepage |
|-----|---------|----------|----------|
| `bsnes` | SNES | `nightly` | [github.com/bsnes-emu/bsnes](https://github.com/bsnes-emu/bsnes) |
| `bsnes-hd-beta` | SNES (HD mode7 fork) | — | [github.com/DerKoun/bsnes-hd](https://github.com/DerKoun/bsnes-hd) |
| `cemu` | Wii U | `dev` | [cemu.info](https://cemu.info) |
| `desmume` | DS | — | [desmume.org](https://desmume.org) |
| `dolphin` | GameCube / Wii | `dev` | [dolphin-emu.org](https://dolphin-emu.org/) |
| `eden` | Switch | — | [eden-emu.dev](https://eden-emu.dev/) |
| `fceux` | NES | — | [fceux.com](https://fceux.com) |
| `gopher64` | N64 | — | [github.com/gopher64/gopher64](https://github.com/gopher64/gopher64) |
| `azahar` | 3DS | — | [github.com/azahar-emu/azahar](https://github.com/azahar-emu/azahar) |
| `melonds` | DS | — | [melonds.kuribo64.net](https://melonds.kuribo64.net/) |
| `mesen` | NES / multi-system | — | [mesen.ca](https://www.mesen.ca) |
| `mesen-s` | SNES | — | [mesen.ca](https://www.mesen.ca) |
| `mgba` | GBA / GB / GBC | `dev` | [mgba.io](https://mgba.io/) |
| `mupen64plus` | N64 | — | [github.com/mupen64plus](https://github.com/mupen64plus/mupen64plus-core) |
| `project64-dev` | N64 | — | [pj64-emu.com](https://www.pj64-emu.com/) |
| `rmg` | N64 | — | [github.com/Rosalie241/RMG](https://github.com/Rosalie241/RMG) |
| `sameboy` | GB / GBC | — | [sameboy.github.io](https://sameboy.github.io/) |
| `snes9x` | SNES | `dev` | [snes9x.com](https://www.snes9x.com/) |
| `visualboyadvance-m` | GB / GBC / GBA | `nightly` | [visualboyadvance-m.org](https://visualboyadvance-m.org) |

### PlayStation

| App | Systems | Variants | Homepage |
|-----|---------|----------|----------|
| `duckstation` | PS1 | `preview` | [github.com/stenzek/duckstation](https://github.com/stenzek/duckstation) |
| `pcsx2` | PS2 | `dev` | [pcsx2.net](https://pcsx2.net/) |
| `ppsspp` | PSP | `dev` | [ppsspp.org](https://www.ppsspp.org) |
| `rpcs3` | PS3 | — | [rpcs3.net](https://rpcs3.net/) |
| `ps3-system-software` | PS3 firmware | — | [playstation.com](https://www.playstation.com/en-us/support/hardware/ps3/system-software/) |
| `shadps4` | PS4 | — | [shadps4.net](https://shadps4.net/) |
| `vita3k` | PS Vita | — | [vita3k.org](https://vita3k.org) |

### Sega

| App | Systems | Variants | Homepage |
|-----|---------|----------|----------|
| `flycast` | Dreamcast / Naomi | — | [github.com/flyinghead/flycast](https://github.com/flyinghead/flycast) |
| `redream` | Dreamcast | `dev` | [redream.io](https://redream.io) |

### Xbox

| App | Systems | Variants | Homepage |
|-----|---------|----------|----------|
| `xemu` | Xbox | — | [xemu.app](https://xemu.app) |
| `xenia` | Xbox 360 | `canary` | [xenia.jp](https://xenia.jp) |

### PC / Engine ports

| App | Description | Variants | Homepage |
|-----|-------------|----------|----------|
| `scummvm` | Classic adventure game engine | `nightly` | [scummvm.org](https://www.scummvm.org/) |

### Fan projects & PC ports

| App | Description | Homepage |
|-----|-------------|----------|
| `2ship2harkinian` | Majora's Mask PC port | [github.com/HarbourMasters/2ship2harkinian](https://github.com/HarbourMasters/2ship2harkinian) |
| `shipwright` | Ocarina of Time PC port | [shipofharkinian.com](https://www.shipofharkinian.com) |
| `spaghettikart` | Mario Kart 64 PC port | [github.com/HarbourMasters/SpaghettiKart](https://github.com/HarbourMasters/SpaghettiKart) |
| `starship` | Star Fox 64 PC port | [github.com/HarbourMasters/Starship](https://github.com/HarbourMasters/Starship) |
| `zelda64recomp` | Zelda 64 recompilation | [github.com/Zelda64Recomp/Zelda64Recomp](https://github.com/Zelda64Recomp/Zelda64Recomp) |
| `sm64coopdx` | SM64 online co-op | [sm64coopdx.com](https://sm64coopdx.com/) |

### Tools

| App | Description | Homepage |
|-----|-------------|----------|
| `mednaffe` | GUI frontend for Mednafen | [github.com/AmatCoder/mednaffe](https://github.com/AmatCoder/mednaffe/) |
| `steam-rom-manager` | ROM shortcut manager for Steam | [steamgriddb.github.io/steam-rom-manager](https://steamgriddb.github.io/steam-rom-manager/) |

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

This bucket checks for updates every hour. You must run update commands manually to apply them:

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

---

## Credits

- [borger](https://github.com/borger) for creating and maintaining this bucket.
- [lukesampson](https://github.com/lukesampson) for creating Scoop and the original Retroarch manifest.
- [hermanjustnu](https://github.com/hermanjustnu/) for the original scoop-emulator repo.
- [Ash258](https://github.com/Ash258) for creating the original RPCS3 manifest.
- [Calinou](https://github.com/Calinou) for creating the scoop-games repository.
- [beyondmeat](https://github.com/beyondmeat) for contributing emulators, fixing bugs, and maintaining manifests.
