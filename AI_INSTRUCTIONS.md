# Scoop Emulators Bucket - AI Instructions

## Core Requirements

This bucket contains emulator manifests validated by 3 tests:

1. **checkver** - Detects latest version
2. **check-autoupdate** - Validates autoupdate config and URLs
3. **check-manifest-install** - Tests manifest installation

All three must pass. PRs auto-merge on pass, escalate to @beyondmeat on failure.

---

## PowerShell Scripts

**Location:** `bin/` directory

**Key scripts:**

- `checkver.ps1` - Detect latest version
- `check-autoupdate.ps1` - Validate autoupdate config
- `check-manifest-install.ps1` - Test manifest installation
- `update-manifest.ps1` - Auto-update version and hashes
- `autofix-manifest.ps1` - Intelligent manifest repair
- `validate-and-merge.ps1` - Full PR validation pipeline

**Usage:**

```powershell
# Single manifest validation
.\bin\checkver.ps1 -Dir bucket -App appname
.\bin\check-autoupdate.ps1 -ManifestPath bucket/app.json
.\bin\check-manifest-install.ps1 -ManifestPath bucket/app.json

# Update and auto-fix
.\bin\update-manifest.ps1 -ManifestPath bucket/app.json -Update
.\bin\autofix-manifest.ps1 -ManifestPath bucket/app.json
```

---

## PowerShell Compatibility (5.1 & 7.x)

**Critical Rules:**

1. **No Special Characters** - Use ASCII only
   - USE: `[OK]`, `[FAIL]`, `[WARN]`, `[SKIP]`, `[INFO]`
   - AVOID: emoji and Unicode checkmarks

2. **File Encoding** - UTF-8 WITHOUT BOM

    ```powershell
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $content, $utf8NoBom)
    ```

   - DO NOT use `Set-Content` or `Out-File` (they add BOM)
   - DO NOT use `UTF8Encoding($true)`

3. **Progress Preference** - Use variable, not parameter

   ```powershell
   $ProgressPreference = 'SilentlyContinue'
   Invoke-WebRequest -Uri $url -OutFile $file
   ```

1. **Avoid Version-Specific Features**
   - SKIP: `??` null-coalescing operator (PS 7.x only)
   - SKIP: `?.` null-conditional (PS 7.x only)
   - USE: `if` statements instead

5. **JSON Trailing Newline** - Always add `+ "`n"`

    ```powershell
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $json + "`n", $utf8NoBom)
    ```

1. **Windows 11 Environment** - Commands should be windows compatible
   - AVOID: Unix utilities like `head`, `tail`, `grep`, `sed`, `awk`
   - USE: PowerShell cmdlets instead:
     - First 5 items: `Select-Object -First 5`
     - Last 5 items: `Select-Object -Last 5`
     - Pattern matching: `Select-String -Pattern pattern`
     - Sorting: `Sort-Object`

---

## File Standards

**All files: UTF-8 WITHOUT BOM, CRLF line endings, trailing newline, NO TRAILING WHITESPACE**

### Critical: UTF-8 WITHOUT BOM

**BOM (Byte Order Mark) breaks GitHub Actions workflows!**

- UTF-8 BOM = `EF BB BF` bytes at start of file
- PowerShell's default `[System.Text.Encoding]::UTF8` **ADDS BOM** (wrong!)

- Use `New-Object System.Text.UTF8Encoding $false` instead (correct!)

**NEVER use:**

```powershell
[System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::UTF8)  # ADDS BOM!
```

**ALWAYS use:**

```powershell
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($path, $content, $utf8NoBom)  # NO BOM!
```

### Additional PS5.1 rules learned

- Always test PowerShell scripts using Windows PowerShell 5.1 (powershell.exe -NoProfile). Do not rely only on PowerShell 7 (pwsh) during development or CI for scripts that must run on Windows host environments.
- Before running or committing changes to a PowerShell script, validate its PS5.1 syntax with the AST parser. Example:

```powershell
# Parse and check for syntax errors (PowerShell 5.1)
$content = [System.IO.File]::ReadAllText('c:\path\to\script.ps1')
$null = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
Write-Host 'Parse OK'
```

- Avoid double-quoted strings that contain bracketed tokens (e.g. "[OK] ...") or regex character classes like "[a-f0-9]". PowerShell 5.1 can interpret `[ ... ]` inside double quotes as an array/type index and raise parse errors. Use single quotes for such literal strings or split interpolation across multiple Write-Host calls.
- When embedding regular expressions or character classes, prefer single-quoted strings (e.g. '[a-f0-9]') so the parser does not misinterpret the bracketed expression.

### Manifest data safety

- Always null-check nested manifest fields before reading or writing (e.g., test `$manifest.architecture` and `$manifest.architecture.'64bit'` before accessing `.url` or `.hash`). Missing checks cause runtime errors for manifests without `architecture` sections — prefer helper guards or short-circuit tests.
- When modifying nested manifest fields, ensure the parent object exists before assignment (e.g., create `$manifest.architecture` and `$manifest.architecture.'64bit'` as needed) to avoid runtime exceptions when adding new fields.

### Script testing checklist (for PS scripts changes)

- Run AST parse check (see example above) using powershell.exe -NoProfile

- Run a representative manifest through `autofix-manifest.ps1` using PowerShell 5.1:

```powershell
powershell -NoProfile -Command "& 'c:\\path\\to\\bin\\autofix-manifest.ps1' -ManifestPath 'c:\\path\\to\\bucket\\melonds.json'"
```

- Run `Scoop-Bucket.Tests.ps1` to validate the full suite
- Verify file writes use UTF-8 without BOM (`New-Object System.Text.UTF8Encoding $false`)
- If adding platform APIs (e.g. Gitea), ensure the API call builder has both base (host) and repository path — prefer passing a base host + repo path rather than assuming a single combined string.

### Critical: Trailing Whitespace

**EVERY LINE MUST END WITH A CHARACTER, NOT SPACES OR TABS!** This includes:

- Empty lines (must be completely empty, not spaces/tabs)
- Lines ending comments
- Lines with PowerShell script blocks (`;` or `|` must be the last character)
- YAML/JSON lines

### By Type

- **PowerShell (.ps1)** - 2 or 4 space indentation, NO trailing whitespace
- **JSON (.json)** - Use `formatjson.ps1` to validate, NO trailing whitespace
- **Markdown (.md)** - No code fence wrapper around entire file, NO trailing whitespace
- **YAML (.yml, .yaml)** - 2 space indentation, NO trailing whitespace (GitHub Actions files are strict!)

### File Validation Checklist

Before committing ANY file changes:

- [ ] UTF-8 encoding WITHOUT BOM (no `EF BB BF` bytes at start)
- [ ] No trailing whitespace (spaces/tabs at end of lines)
- [ ] Empty lines are completely empty (not spaces/tabs)
- [ ] File ends with exactly one newline (`\n`)

- [ ] Line endings are CRLF (`\r\n` on Windows) or consistent

- [ ] Indentation is consistent (2 or 4 spaces, no tabs)

**Quick PowerShell validation:**

```powershell
# Check for BOM
$bytes = [System.IO.File]::ReadAllBytes("file.yml")
if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Write-Host "ERROR: BOM detected (must be removed)"
} else {
    Write-Host "OK: No BOM"
}

# Find lines with trailing whitespace
$content = Get-Content -Path "file.yml" -Raw
$lines = $content -split "`n"
$lines | ForEach-Object { if ($_ -match '\s+$') { Write-Host "Trailing whitespace found" } }

# Fix: Remove BOM and trailing whitespace, ensure UTF-8 without BOM
$content = Get-Content -Path "file.yml" -Raw
$cleaned = $content -replace '\s+\r\n', "`r`n"  # Remove trailing whitespace
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText("file.yml", $cleaned + "`r`n", $utf8NoBom)
Write-Host "File cleaned: BOM removed, trailing whitespace removed"
```

---

## Manifest Structure

### Core Fields

- `version` - Emulator version (semantic version or `"nightly"`/`"dev"`)
- `description` - Brief description
- `homepage` - Project URL
- `license` - License type
- `architecture` - Platform-specific URLs and SHA256 hashes (32bit/64bit)

- `bin` - Executable file(s)

- `checkver` - Configuration for detecting latest version
- `autoupdate` - Configuration for automatic updates (uses `$version` placeholder)

### Autoupdate Patterns

```json
"autoupdate": {
    "architecture": {
```

"64bit": { "url": "<https://example.com/v$version/app-x64.zip>", "hash": "sha256|..." },        "64bit": { "url": "<https://example.com/v$version/app-x64.zip>", "hash": "sha256|..." },
        "32bit": { "url": "<https://example.com/v$version/app-x86.zip>", "hash": "sha256|..." }

```text
}
```

}

```text

### Version Detection (checkver)
Common configurations:

```

```json
"checkver": {
    "github": "<https://github.com/owner/repo>"
}
```

or with regex:

```json
"checkver": {
    "url": "<https://api.github.com/repos/owner/repo/releases/latest>",
```

"jp": "$.tag_name",    "jp": "$.tag_name",
    "re": "v(.+)"
}

```text

### Special Cases

- **Nightly Builds** - Version: `"nightly"` or `"dev"`, no hash required (Scoop skips verification), static URLs
- **Git Commits** - Version is commit hash extracted by checkver, autoupdate substitutes hash into URL
- **32-bit Optional** - If 32-bit URL returns 404, script falls back to only 64-bit
- **Pre-release Versions** - Checkver may need to filter out pre-releases with regex

### Common Issues & Fixes

| Problem | Cause | Solution |
| Problem | Cause | Solution |
|---------|-------|----------|
| Autoupdate fails | URL contains `$version` but manifest version format doesn't match | Check version pattern in checkver config |
| 404 on 32-bit downloads | 32-bit builds don't exist for newer versions | Remove 32-bit from autoupdate; script handles gracefully |
| Hash mismatch after update | Downloaded file changed | Re-run `update-manifest.ps1` to recalculate SHA256 |
| Checkver returns error | Invalid URL or regex pattern | Review checkver section; test with sample version strings |
| Autoupdate URL broken | Download host changed or version format changed | Update URL template; test URLs exist before committing |

---

## Common Workflows

**Manual Testing:**

```

```powershell
.\bin\checkver.ps1 -Dir bucket -App appname                    # Check version
.\bin\check-autoupdate.ps1 -ManifestPath bucket/app.json       # Validate autoupdate
.\bin\update-manifest.ps1 -ManifestPath bucket/app.json -Update # Update version/hashes
.\bin\check-manifest-install.ps1 -ManifestPath bucket/app.json # Test installation
```

**Auto-Fix Issues:**

```text

```

```powershell
.\bin\autofix-manifest.ps1 -ManifestPath bucket/app.json
```

**Full PR Validation:**

```text

```

```powershell
.\bin\validate-and-merge.ps1 -ManifestPath bucket/app.json -BucketPath bucket `
  -PullRequestNumber 123 -GitHubToken $token -GitHubRepo "owner/repo"
```

---

## Script Details

### checkver.ps1 & check-autoupdate.ps1

- Validate version detection and autoupdate configuration
- Exit codes: 0 = success, -1 = error
- checkver: Detect latest version; check-autoupdate: Validate URLs and placeholders

### check-manifest-install.ps1

- Test manifest installation: Install → verify → uninstall → cleanup
- Catches broken URLs, hash mismatches, missing files

### update-manifest.ps1

- Auto-update version and SHA256 hashes
- Process: checkver → download files → calculate hashes → update manifest
- **Critical:** Always write files using UTF-8 WITHOUT BOM (use `New-Object System.Text.UTF8Encoding $false`) to avoid breaking workflows

### autofix-manifest.ps1

- Repair common issues: 404 errors, URL patterns, checkver config, hashes
- Supports GitHub, GitLab, Gitea repositories

### validate-and-merge.ps1

- Full PR validation: Run all 3 tests → post results → auto-merge or request fixes

- On failure: Retry up to 10 times with @copilot, then escalate to @beyondmeat

---

## Update Workflow

**When to update:**

- Automatic nightly updates via excavator.yml (skips nightly/dev builds)
- Manual: Version mismatch, build location changed, site updated, new platform support

**Before committing:**

```text

```

```text

```

```powershell
.\bin\update-manifest.ps1 -ManifestPath bucket/app.json -Update    # Update version/hashes
.\bin\check-autoupdate.ps1 -ManifestPath bucket/app.json           # Validate autoupdate
.\bin\check-manifest-install.ps1 -ManifestPath bucket/app.json     # Test installation

## If issues: .\bin\autofix-manifest.ps1 -ManifestPath bucket/app.json
```

---

## Known Manifest Patterns

**Standard Release** (melonds, visualboyadvance-m):

- Version: Semantic (e.g., `"2.2.3"`), Hash: Required, Checkver: GitHub API

**Nightly Build** (scummvm-nightly, visualboyadvance-m-nightly):

- Version: `"nightly"` or `"dev"`, Hash: DO NOT include (breaks updates), Static URLs, No `$version` placeholder
- **CRITICAL:** Never add hash to nightly manifests

**Git-Based Version** (desmume):

- Version: 7-char commit hash, Hash: Required, Checkver: Extracts from GitHub API

---

## Important Notes for AI

### Key Rules

- **Hash Verification:** Regular manifests require SHA256 hash. Nightly/dev must NOT have hash (Scoop skips verification)
- **Checkver & Autoupdate:** Checkver must exist first. Version format in checkver must match URL template format
- **Architecture:** 32-bit optional. If 32-bit URL returns 404, fallback to 64-bit only
- **URL Placeholder:** `$version` is replaced as-is; no trim/lowercase (watch for `v2.2.3` vs `2.2.3`)
- **File Encoding:** Always use `New-Object System.Text.UTF8Encoding $false` for file writes to avoid BOM (never `Set-Content`, `Out-File`, or `[System.Text.Encoding]::UTF8` without the no-BOM flag)

### Troubleshooting

| Issue | Likely Cause | Debug Step |

| Issue | Likely Cause | Debug Step || Issue | Likely Cause | Debug Step |
| ------- | -------------- | ----------- |  |  |  |  |
| Checkver fails | Invalid URL, broken regex, auth required | Test URL manually with Invoke-WebRequest |  |  |  |  |
| Autoupdate fails | Version format mismatch with URL template | Manually substitute version and verify URL exists |  |  |  |  |
| Install fails | Broken URL or hash mismatch | Verify URLs download, recalculate hash if needed |  |  |  |  |

### Testing Before Commit

**After modifying a manifest (created or changed):**

```text

```

```text

```

```text

```

```powershell

## Run ALL validation tests - all must pass

.\bin\checkver.ps1 -Dir bucket -App appname                    # Does version detection work?
.\bin\checkurls.ps1 -ManifestPath bucket/app.json              # Are download URLs accessible?
.\bin\check-autoupdate.ps1 -ManifestPath bucket/app.json       # Is autoupdate config valid?
.\bin\check-manifest-install.ps1 -ManifestPath bucket/app.json # Does it actually install?
```

**After modifying any PowerShell script in `bin/`:**

```text

```

```text

```

```text

```

```text

```

```text

```

```text

```

```text

```

```powershell

## Run entire test suite to check for errors

.\Scoop-Bucket.Tests.ps1
```

All tests MUST pass before committing. If manifest tests fail, run `autofix-manifest.ps1` to attempt fixes.

---

## Git Commits

Use conventional commits format:

**Types:** `feat`, `fix`, `chore`, `docs`, `test`

**Scope:** Manifest name or script (e.g., `melonds`, `checkver.ps1`)

**Examples:**

```text

```

```text
feat(melonds): add manifest for melonds emulator
fix(rpcs3): update checkver regex for version detection
fix(visualboyadvance-m): add 32-bit support in autoupdate
```

---
