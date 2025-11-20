param(
    [Parameter(Mandatory = $false)]
    [string]$GitHubUrl,

    [Parameter(Mandatory = $false)]
    [string]$GitLabUrl,

    [Parameter(Mandatory = $false)]
    [int]$IssueNumber,

    [Parameter(Mandatory = $false)]
    [string]$GitHubToken,

    [switch]$AutoApprove
)

$ErrorActionPreference = 'Stop'

# Verify at least one input method is provided
if (-not $GitHubUrl -and -not $GitLabUrl -and -not $IssueNumber) {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Scoop Manifest Creator" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Automatically generates Scoop manifests for GitHub/GitLab releases." -ForegroundColor Yellow
    Write-Host "Auto-detects and configures stable, nightly, and dev builds." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Green
    Write-Host ""
    Write-Host "  From GitHub repository:"
    Write-Host "    .\create-manifest.ps1 -GitHubUrl 'https://github.com/owner/repo'"
    Write-Host ""
    Write-Host "  From GitLab repository:"
    Write-Host "    .\create-manifest.ps1 -GitLabUrl 'https://gitlab.com/owner/repo'"
    Write-Host ""
    Write-Host "  From GitHub tag/release:"
    Write-Host "    .\create-manifest.ps1 -GitHubUrl 'https://github.com/owner/repo/releases/tag/nightly'"
    Write-Host ""
    Write-Host "  From GitHub issue (auto-updates issue):"
    Write-Host "    .\create-manifest.ps1 -IssueNumber 123 -GitHubToken 'ghp_xxx'"
    Write-Host ""
    Write-Host "Parameters:" -ForegroundColor Green
    Write-Host "  -GitHubUrl    GitHub repository or release URL"
    Write-Host "  -GitLabUrl    GitLab repository URL"
    Write-Host "  -IssueNumber  GitHub issue number (extracts repo from issue body)"
    Write-Host "  -GitHubToken  GitHub personal access token (required for -IssueNumber)"
    Write-Host ""
    Write-Host "Detected Build Types:" -ForegroundColor Green
    Write-Host "  Stable       Tag format: v1.2.3, 1.2.3, release (with hash)"
    Write-Host "  Nightly      Tag format: nightly, continuous, canary (no hash)"
    Write-Host "  Dev/Preview  Pre-release GitHub releases (no hash)"
    Write-Host ""
    Write-Host "Features:" -ForegroundColor Green
    Write-Host "  - Auto-detects platform (emulator type) if applicable"
    Write-Host "  - Downloads asset and monitors for portable data"
    Write-Host "  - Calculates or retrieves SHA256 checksums"
    Write-Host "  - Generates checkver and autoupdate configs"
    Write-Host "  - Proper hash handling for nightly/dev builds"
    Write-Host "  - GitHub issue integration with auto-comments"
    Write-Host ""
    exit 0
}

# Helper functions
function Test-IsNightlyBuild {
    param([string]$TagName)

    $nightlyPatterns = @('nightly', 'continuous', 'dev', 'latest', 'main', 'master', 'trunk', 'canary')
    $lowerTag = $TagName.ToLower()

    foreach ($pattern in $nightlyPatterns) {
        if ($lowerTag -match $pattern) {
            return $true
        }
    }

    return $false
}

function Get-GitHubRepoInfo {
    param([string]$Url)

    # Handle various GitHub URL formats: /releases/tag/tagname, /releases/latest, or just repo URL
    $match = $Url -match 'github\.com/([^/]+)/([^/?]+)'
    if (-not $match) {
        throw "Invalid GitHub URL format. Expected: https://github.com/owner/repo"
    }

    $owner = $matches[1]
    $repo = $matches[2]

    # Check if URL contains a specific tag
    $tagMatch = $Url -match '/releases/tag/([^/?]+)'
    if ($tagMatch) {
        $tagName = $matches[1]
        $apiUrl = "https://api.github.com/repos/$owner/$repo/releases/tags/$tagName"
        Write-Host "[INFO] Fetching release info for tag: $tagName" -ForegroundColor Cyan
    } else {
        $apiUrl = "https://api.github.com/repos/$owner/$repo/releases/latest"
        Write-Host "[INFO] Fetching latest release info from: $apiUrl" -ForegroundColor Cyan
    }

    $response = Invoke-WebRequest -Uri $apiUrl -ErrorAction Stop
    $releaseInfo = $response.Content | ConvertFrom-Json

    $buildType = "stable"
    $isNightly = Test-IsNightlyBuild -TagName $releaseInfo.tag_name
    $isPreRelease = $releaseInfo.prerelease

    if ($isNightly) {
        $buildType = "nightly"
        Write-Host "[OK] Detected nightly/continuous build" -ForegroundColor Green
    } elseif ($isPreRelease) {
        $buildType = "dev"
        Write-Host "[OK] Detected pre-release build" -ForegroundColor Green
    }

    return @{
        Owner        = $owner
        Repo         = $repo
        TagName      = $releaseInfo.tag_name
        Version      = if ($buildType -eq "nightly") { "nightly" } elseif ($buildType -eq "dev") { "dev" } else { $releaseInfo.tag_name -replace '^v', '' }
        Assets       = $releaseInfo.assets
        RepoUrl      = "https://github.com/$owner/$repo"
        Platform     = "github"
        BuildType    = $buildType
        IsPrerelease = $isPreRelease
        License      = $null
        Description  = $null
    }
}

function Get-GitLabRepoInfo {
    param([string]$Url)

    $match = $Url -match 'gitlab\.com/([^/]+)/([^/]+)/?$'
    if (-not $match) {
        throw "Invalid GitLab URL format. Expected: https://gitlab.com/owner/repo"
    }

    $owner = $matches[1]
    $repo = $matches[2]

    # GitLab API uses encoded paths (/ becomes %2F)
    $projectPath = "$owner%2F$repo"
    $apiUrl = "https://gitlab.com/api/v4/projects/$projectPath/releases"
    Write-Host "[INFO] Fetching release info from: $apiUrl" -ForegroundColor Cyan

    $response = Invoke-WebRequest -Uri $apiUrl -ErrorAction Stop
    $releases = $response.Content | ConvertFrom-Json

    if ($releases.Count -eq 0) {
        throw "No releases found in GitLab repository"
    }

    $latestRelease = $releases[0]

    # Convert GitLab release format to common format
    $assets = @()
    if ($latestRelease.assets.sources) {
        $assets = $latestRelease.assets.sources
    }

    return @{
        Owner       = $owner
        Repo        = $repo
        TagName     = $latestRelease.tag_name
        Version     = $latestRelease.tag_name -replace '^v', ''
        Assets      = $assets
        RepoUrl     = $Url
        Platform    = "gitlab"
        License     = $null
        Description = $latestRelease.description
    }
}

function Get-GitHubIssueInfo {
    param(
        [int]$IssueNumber,
        [string]$Token
    )

    $bucketOwner = "borger"
    $bucketRepo = "scoop-emulators"
    $apiUrl = "https://api.github.com/repos/$bucketOwner/$bucketRepo/issues/$IssueNumber"

    Write-Host "[INFO] Fetching issue #$IssueNumber..." -ForegroundColor Cyan

    $headers = @{
        "Authorization" = "token $Token"
        "Accept"        = "application/vnd.github.v3+json"
    }

    try {
        $response = Invoke-WebRequest -Uri $apiUrl -Headers $headers -ErrorAction Stop
        $issueInfo = $response.Content | ConvertFrom-Json

        # Extract GitHub or GitLab URL from issue body
        $urlMatch = $issueInfo.body -match '(https?://(github|gitlab)\.com/[^/]+/[^/\s)]+)'
        if (-not $urlMatch) {
            throw "No GitHub/GitLab repository URL found in issue body"
        }

        $repoUrl = $matches[1]
        Write-Host "[OK] Found repository URL: $repoUrl" -ForegroundColor Green

        return @{
            IssueNumber = $IssueNumber
            IssueTitle  = $issueInfo.title
            IssueBody   = $issueInfo.body
            RepoUrl     = $repoUrl
            IssueUrl    = $issueInfo.html_url
        }
    } catch {
        throw "Failed to fetch issue: $_"
    }
}

function Update-GitHubIssue {
    param(
        [int]$IssueNumber,
        [string]$Token,
        [string]$Comment,
        [string[]]$Labels = @()
    )

    $bucketOwner = "borger"
    $bucketRepo = "scoop-emulators"
    $apiUrl = "https://api.github.com/repos/$bucketOwner/$bucketRepo/issues/$IssueNumber"

    $headers = @{
        "Authorization" = "token $Token"
        "Accept"        = "application/vnd.github.v3+json"
    }

    # Add comment
    if ($Comment) {
        $commentUrl = "$apiUrl/comments"
        $body = @{ body = $Comment } | ConvertTo-Json

        try {
            Invoke-WebRequest -Uri $commentUrl -Headers $headers -Method Post -Body $body -ContentType "application/json" | Out-Null
            Write-Host "[OK] Added comment to issue #$IssueNumber" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Failed to add comment: $_" -ForegroundColor Yellow
        }
    }

    # Add labels
    if ($Labels.Count -gt 0) {
        $labelBody = @{ labels = $Labels } | ConvertTo-Json

        try {
            Invoke-WebRequest -Uri $apiUrl -Headers $headers -Method Patch -Body $labelBody -ContentType "application/json" | Out-Null
            Write-Host "[OK] Updated issue labels" -ForegroundColor Green
        } catch {
            Write-Host "[WARN] Failed to update labels: $_" -ForegroundColor Yellow
        }
    }
}

function Get-RepositoryMetadata {
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$Platform = "github"
    )

    if ($Platform -eq "github") {
        $apiUrl = "https://api.github.com/repos/$owner/$repo"
        Write-Host "[INFO] Fetching repository metadata..." -ForegroundColor Cyan

        $response = Invoke-WebRequest -Uri $apiUrl -ErrorAction Stop
        $repoInfo = $response.Content | ConvertFrom-Json

        $metadata = @{
            Description = $repoInfo.description
            License     = $repoInfo.license.spdx_id
            LicenseUrl  = if ($repoInfo.license) { "https://raw.githubusercontent.com/$owner/$repo/main/LICENSE" } else { $null }
        }
    } else {
        # GitLab
        $projectPath = "$owner%2F$repo"
        $apiUrl = "https://gitlab.com/api/v4/projects/$projectPath"
        Write-Host "[INFO] Fetching repository metadata..." -ForegroundColor Cyan

        $response = Invoke-WebRequest -Uri $apiUrl -ErrorAction Stop
        $repoInfo = $response.Content | ConvertFrom-Json

        $metadata = @{
            Description = $repoInfo.description
            License     = $null
            LicenseUrl  = $null
        }
    }

    return $metadata
}

function Find-WindowsExecutable {
    param([object[]]$Assets)

    # Filter for Windows assets
    $windowsAssets = @($Assets | Where-Object { $_.name -match 'windows|win|x64|x86_64|amd64' })

    if ($windowsAssets.Count -eq 0) {
        throw "No Windows assets found in release"
    }

    # Scoring system for asset selection
    $scored = @()
    foreach ($asset in $windowsAssets) {
        $score = 0
        $name = $asset.name.ToLower()

        # File type preferences (archives are better than installers)
        if ($name -match '\.zip$') { $score += 100 }
        elseif ($name -match '\.7z$') { $score += 90 }
        elseif ($name -match '\.tar\.gz$' -or $name -match '\.tgz$') { $score += 80 }
        elseif ($name -match '\.exe$') { $score += 0 }
        else { continue }  # Skip other file types

        # Build configuration preferences
        if ($name -match 'sdl2') { $score += 50 }
        if ($name -match 'msys2|mingw') { $score += 40 }
        if ($name -match 'msvc') { $score -= 20 }

        # Architecture preference (64-bit preferred)
        if ($name -match 'x64|x86_64|amd64') { $score += 10 }

        $scored += [PSCustomObject]@{
            Asset = $asset
            Score = $score
            Name  = $name
        }
    }

    if ($scored.Count -eq 0) {
        throw "No suitable Windows assets found (unsupported file types)"
    }

    # Sort by score descending
    $best = $scored | Sort-Object -Property Score -Descending | Select-Object -First 1
    $asset = $best.Asset

    Write-Host "[OK] Selected: $($asset.name)" -ForegroundColor Green
    Write-Host "[INFO] Asset score: $($best.Score) (archive=$([int]($best.Name -match '\.zip|\.7z|\.tar\.gz')), sdl2=$([int]($best.Name -match 'sdl2')), msys2=$([int]($best.Name -match 'msys2|mingw')))" -ForegroundColor Cyan

    return $asset
}

function Download-Asset {
    param(
        [object]$Asset,
        [string]$OutputDir
    )

    $ProgressPreference = 'SilentlyContinue'

    # Ensure TLS 1.2 is enabled
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

    $downloadUrl = if ($Asset.browser_download_url) { $Asset.browser_download_url } else { $Asset.url }
    $fileName = $Asset.name
    $outputPath = Join-Path $OutputDir $fileName

    # Create a cache directory for downloaded files
    $cacheDir = Join-Path $env:TEMP "manifest-creator-cache"
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    $cachedFilePath = Join-Path $cacheDir $fileName

    # Check if file is already cached
    if (Test-Path $cachedFilePath) {
        Write-Host "[INFO] Using cached file: $fileName" -ForegroundColor Cyan
        Copy-Item -Path $cachedFilePath -Destination $outputPath -Force | Out-Null
        Write-Host "[OK] Copied from cache to: $outputPath" -ForegroundColor Green
        return $outputPath
    }

    # Download the file
    Write-Host "[INFO] Downloading: $fileName" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $downloadUrl -OutFile $cachedFilePath -ErrorAction Stop
    Write-Host "[OK] Downloaded to cache: $cachedFilePath" -ForegroundColor Green

    # Copy from cache to output directory
    Copy-Item -Path $cachedFilePath -Destination $outputPath -Force | Out-Null
    Write-Host "[OK] Copied to: $outputPath" -ForegroundColor Green

    return $outputPath
}

function Extract-Archive {
    param([string]$ArchivePath, [string]$ExtractDir)

    Write-Host "[INFO] Extracting archive..." -ForegroundColor Cyan
    if (Test-Path $ExtractDir) {
        Remove-Item $ExtractDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null

    Expand-Archive -Path $ArchivePath -DestinationPath $ExtractDir -ErrorAction Stop
    Write-Host "[OK] Archive extracted to: $ExtractDir" -ForegroundColor Green

    return $ExtractDir
}

function Find-ExecutableInDirectory {
    param(
        [string]$Directory,
        [string]$ProjectName
    )

    $exes = @(Get-ChildItem -Path $Directory -Filter '*.exe' -Recurse | Select-Object -First 10)
    if ($exes.Count -eq 0) {
        throw "No executables found in extracted archive"
    }

    if ($exes.Count -eq 1) {
        Write-Host "[OK] Found executable: $($exes[0].Name)" -ForegroundColor Green
        return $exes[0]
    }

    # Smart selection: prefer executable matching project name
    $projectNameLower = $ProjectName.ToLower()

    # First, try exact project name match (e.g., "azahar.exe" for "azahar")
    $exactMatch = @($exes | Where-Object { $_.BaseName.ToLower() -eq $projectNameLower })
    if ($exactMatch.Count -gt 0) {
        Write-Host "[OK] Found matching executable: $($exactMatch[0].Name)" -ForegroundColor Green
        return $exactMatch[0]
    }

    # Second, try prefix match without -gui/-ui suffixes
    $prefixMatches = @($exes | Where-Object {
            $baseName = $_.BaseName.ToLower()
            $baseName -match "^$([regex]::Escape($projectNameLower))(-gui|-ui)?$"
        })

    if ($prefixMatches.Count -gt 0) {
        # Prefer the one without -gui/-ui if available
        $noSuffix = @($prefixMatches | Where-Object { $_.BaseName.ToLower() -eq $projectNameLower })
        if ($noSuffix.Count -gt 0) {
            Write-Host "[OK] Found matching executable: $($noSuffix[0].Name)" -ForegroundColor Green
            return $noSuffix[0]
        }
        # Otherwise use the first match (probably -gui or -ui)
        Write-Host "[OK] Found matching executable: $($prefixMatches[0].Name)" -ForegroundColor Green
        return $prefixMatches[0]
    }

    # Fallback: show all options if no smart match found
    Write-Host "[WARN] Multiple executables found. Please select one:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $exes.Count; $i++) {
        Write-Host "  [$($i + 1)] $($exes[$i].Name)"
    }
    $choice = Read-Host "Select executable (1-$($exes.Count))"
    $selectedIndex = [int]$choice - 1

    if ($selectedIndex -lt 0 -or $selectedIndex -ge $exes.Count) {
        throw "Invalid selection"
    }

    return $exes[$selectedIndex]
}

function Detect-Platform {
    param([string]$RepoName, [string]$Description)

    $emulatorPatterns = @{
        'gopher64|mupen64|n64'          = 'Nintendo 64'
        'dolphin'                       = 'Nintendo GameCube/Wii'
        'pcsx2'                         = 'PlayStation 2'
        'rpcs3'                         = 'PlayStation 3'
        'cemu|wiiu'                     = 'Nintendo Wii U'
        'yuzu|ryujinx'                  = 'Nintendo Switch'
        'citra'                         = 'Nintendo 3DS'
        'melonds'                       = 'Nintendo DS'
        'fceux|snes9x|bsnes|mesen'      = 'Super Nintendo'
        'retroarch|advancemame'         = 'Multi-System'
        'xemu|cxbx'                     = 'Microsoft Xbox'
        'xenia'                         = 'Microsoft Xbox 360'
        'flycast|redream|demul'         = 'Sega Dreamcast'
        'genesis|mega'                  = 'Sega Genesis'
        'duckstation|mednafen|pcsx'     = 'PlayStation 1'
        'ppsspp'                        = 'PlayStation Portable'
        'mgba|visualboyadvance|sameboy' = 'Game Boy/Color'
        'mame'                          = 'Arcade'
    }

    $searchText = "$RepoName $Description".ToLower()

    foreach ($pattern in $emulatorPatterns.Keys) {
        if ($searchText -match $pattern) {
            return $emulatorPatterns[$pattern]
        }
    }

    return $null
}

function Get-ReleaseChecksum {
    param(
        [object[]]$Assets,
        [string]$TargetAssetName,
        [string]$DownloadUrl = $null
    )

    $checksumPatterns = @('*.sha256', '*.sha256sum', '*.sha256.txt', '*.checksum', '*.hashes', '*.DIGEST', '*.md5', '*.md5sum')
    $checksumAssets = @()

    foreach ($pattern in $checksumPatterns) {
        $checksumAssets += @($Assets | Where-Object { $_.name -like $pattern })
    }

    if ($checksumAssets.Count -gt 0) {
        foreach ($checksumAsset in $checksumAssets) {
            try {
                $ProgressPreference = 'SilentlyContinue'
                $tempFile = Join-Path $env:TEMP "checksum-$(Get-Random).txt"
                $downloadUrl = if ($checksumAsset.browser_download_url) { $checksumAsset.browser_download_url } else { $checksumAsset.url }
                Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -ErrorAction Stop

                $content = Get-Content -Path $tempFile -Raw
                $lines = $content -split "`n" | Where-Object { $_ -match '\S' }

                foreach ($line in $lines) {
                    if ($line -match '^([a-f0-9]{64})\s+(.+?)$' -or $line -match '^(.+?)\s+([a-f0-9]{64})$') {
                        $hash = if ($matches[1] -match '^[a-f0-9]{64}$') { $matches[1] } else { $matches[2] }
                        $filename = if ($matches[1] -match '^[a-f0-9]{64}$') { $matches[2] } else { $matches[1] }

                        if ($filename -like "*$($TargetAssetName)*" -or $TargetAssetName -like "*$filename*") {
                            Write-Host "[OK] Found SHA256 from release: $hash" -ForegroundColor Green
                            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                            return $hash
                        }
                    }
                }
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Host "[WARN] Failed to parse checksum file: $_" -ForegroundColor Yellow
            }
        }
    }

    return $null
}

function Monitor-ExecutableCreation {
    param(
        [string]$ExecutablePath,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 10
    )

    Write-Host "[INFO] Creating portable structure..." -ForegroundColor Cyan

    # Create folder structure for monitoring (will be used as fallback if no app-specific folders found)
    $userFolder = Join-Path $WorkingDirectory "user"
    $portableFolder = Join-Path $WorkingDirectory "portable"

    New-Item -ItemType Directory -Path $userFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $portableFolder -Force | Out-Null

    Write-Host "[INFO] Monitoring for files/folders created during execution..." -ForegroundColor Cyan
    Write-Host "[INFO] Timeout: ${TimeoutSeconds}s (close the application to continue)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "IMPORTANT - Persist Configuration" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "The application will now launch. Before closing it:" -ForegroundColor Cyan
    Write-Host "  1. Change some settings in the application" -ForegroundColor Cyan
    Write-Host "  2. Create or modify files/preferences" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "WARNING: If you don't change any settings, the persist" -ForegroundColor Yellow
    Write-Host "folder will be empty, and your data will NOT be saved!" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "After making changes, close the application normally." -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""

    $initialSnapshot = @{}
    Get-ChildItem -Path $WorkingDirectory -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { $initialSnapshot[$_.FullName] = $_.LastWriteTime }

    try {
        $process = Start-Process -FilePath $ExecutablePath -WorkingDirectory $WorkingDirectory -PassThru -ErrorAction Stop
        $startTime = Get-Date

        while (-not $process.HasExited -and ((Get-Date) - $startTime).TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Milliseconds 500
        }

        if (-not $process.HasExited) {
            Write-Host "[INFO] Timeout reached or application still running. Press ENTER to continue..." -ForegroundColor Cyan
            Read-Host
            $process | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "[WARN] Could not start executable for monitoring: $_" -ForegroundColor Yellow
        return @()
    }

    $createdItems = @()
    Get-ChildItem -Path $WorkingDirectory -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object {
        if (-not $initialSnapshot.ContainsKey($_.FullName)) {
            $createdItems += $_.FullName
        }
    }

    # Check if user and portable folders have content
    $userFolderPath = Join-Path $WorkingDirectory "user"
    $portableFolderPath = Join-Path $WorkingDirectory "portable"

    $persistItems = @()
    $usesStandardFolders = $false

    # Only persist top-level folders (user and portable)
    # Add user folder if it has files
    if ((Test-Path $userFolderPath) -and (Get-ChildItem $userFolderPath -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        $persistItems += "user"
        $usesStandardFolders = $true
        Write-Host "[OK] 'user' folder has content, will persist" -ForegroundColor Green
    }

    # Add portable folder if it has files
    if ((Test-Path $portableFolderPath) -and (Get-ChildItem $portableFolderPath -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        $persistItems += "portable"
        $usesStandardFolders = $true
        Write-Host "[OK] 'portable' folder has content, will persist" -ForegroundColor Green
    }

    # Ignore other created items - only persist user/portable top-level folders
    if ($createdItems.Count -gt 0) {
        Write-Host "[INFO] Detected other created items (only top-level persist folders will be used):" -ForegroundColor Cyan
        foreach ($item in $createdItems | Select-Object -First 10) {
            $relativePath = $item -replace [regex]::Escape($WorkingDirectory), '' -replace '^\\', ''
            # Skip portable.txt and user/portable folders themselves
            if ($relativePath -and $relativePath -notmatch '^(portable\.txt|user|portable)(\\|$)') {
                Write-Host "  - $relativePath"
            }
        }

        if ($createdItems.Count -gt 10) {
            Write-Host "  ... and $($createdItems.Count - 10) more" -ForegroundColor Gray
        }
    }

    # Return hashtable with persist items and flags
    # UsesStandardFolders indicates if user/portable folders are being persisted
    $result = @{
        Items               = $persistItems
        HasPersist          = $persistItems.Count -gt 0
        UsesStandardFolders = $usesStandardFolders
    }

    return $result
}

function Calculate-FileHash {
    param([string]$FilePath)

    $hash = Get-FileHash -Path $FilePath -Algorithm SHA256
    return $hash.Hash
}

function Build-Manifest {
    param(
        [hashtable]$RepoInfo,
        [object]$Asset,
        [string]$ExecutableName,
        [array]$PersistItems,
        [hashtable]$Metadata,
        [string]$Platform,
        [string]$BuildType = "stable",
        [bool]$UsesStandardFolders = $false
    )

    # For nightly/dev builds, use static version strings
    $versionToUse = if ($BuildType -eq "nightly") { "nightly" } elseif ($BuildType -eq "dev") { "dev" } else { $RepoInfo.Version }

    $manifest = [ordered]@{
        "version"  = $versionToUse
        "homepage" = $RepoInfo.RepoUrl
    }

    # Use detected platform description, or repository description if not an emulator
    if ($Platform) {
        $manifest["description"] = "$Platform Emulator"
    } elseif ($Metadata.Description) {
        $manifest["description"] = $Metadata.Description
    } else {
        $manifest["description"] = $RepoInfo.Repo
    }

    if ($Metadata.License) {
        $manifest["license"] = [ordered]@{
            "identifier" = $Metadata.License
        }
        if ($Metadata.LicenseUrl) {
            $manifest["license"]["url"] = $Metadata.LicenseUrl
        }
    } else {
        $manifest["license"] = "GPL-2.0"
    }

    # Only include hash for stable releases with calculated/available checksums
    $hashValue = $null
    if ($BuildType -eq "stable" -and -not $Asset.HasChecksumFile) {
        # Only use calculated hash if there's no automated way to get it
        # In architecture section, use just lowercase hash (no prefix)
        $hashValue = $Asset.Checksum.ToLower()
    }
    # For nightly/dev, don't include hash (Scoop skips verification)
    # For stable releases with checksum files, hash is retrieved programmatically

    $archBlock = [ordered]@{
        "url" = $Asset.browser_download_url
    }
    if ($hashValue) {
        $archBlock["hash"] = $hashValue
    }

    $architecture = [ordered]@{
        "64bit" = $archBlock
    }
    $manifest["architecture"] = $architecture

    $manifest["bin"] = $ExecutableName

    # Create shortcut label with platform and executable name
    if ($Platform) {
        # Map platforms to standard abbreviations
        $platformAbbrev = @{
            "Nintendo 64"           = "n64"
            "Nintendo GameCube/Wii" = "gc"
            "Nintendo Wii U"        = "wiiu"
            "Nintendo Switch"       = "switch"
            "Nintendo 3DS"          = "3ds"
            "Nintendo DS"           = "ds"
            "Super Nintendo"        = "snes"
            "Nintendo"              = "nes"
            "PlayStation 1"         = "ps1"
            "PlayStation 2"         = "ps2"
            "PlayStation 3"         = "ps3"
            "PlayStation Portable"  = "psp"
            "Sega Genesis"          = "genesis"
            "Sega Dreamcast"        = "dreamcast"
            "Game Boy"              = "gb"
            "Arcade"                = "arcade"
            "Multi-System"          = "multi"
        }

        $abbrev = $platformAbbrev[$Platform]
        if (-not $abbrev) {
            $abbrev = ($Platform -split '\s' | Select-Object -First 1).ToLower()
        }

        $exeName = $ExecutableName -replace '\.exe$', ''
        $shortcutLabel = "$Platform [$abbrev][$exeName]"
    } else {
        # For non-emulators, use the executable name or repo name
        $appName = $ExecutableName -replace '\.exe$', ''
        $shortcutLabel = $appName
    }
    $manifest["shortcuts"] = @(@($ExecutableName, $shortcutLabel))

    # Build persist array - only include items that were actually created
    $persistArray = @()
    if ($PersistItems.Count -gt 0) {
        $validItems = $PersistItems | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        if ($validItems.Count -gt 0) {
            $persistArray = $validItems
        }
    }

    # Only add persist key if there are items to persist
    if ($persistArray.Count -gt 0) {
        $manifest["persist"] = $persistArray
    }

    # Create portable.txt marker file and ensure persist folders exist
    # Build list of persist folders from PersistItems
    $persistFolders = @()
    foreach ($item in $PersistItems) {
        # Extract top-level folder name (before first backslash if it's a path)
        $topLevelFolder = ($item -split '\\')[0]
        if ($topLevelFolder -and $persistFolders -notcontains $topLevelFolder) {
            $persistFolders += $topLevelFolder
        }
    }

    # Only create portable.txt if NOT using standard folders (user/portable)
    # If using standard folders, assume the app handles its own portable mode
    $portableTxtCode = ""
    if (-not $UsesStandardFolders) {
        $portableTxtCode = @"
# Create portable marker file (used as fallback indicator for portable mode)
Add-Content -Path "`$dir\portable.txt" -Value '' -Encoding UTF8
"@
    }

    # Only add folder creation code if folders actually contain files
    # (Don't create empty folders in preinstall; let Scoop manage folder creation)
    $folderCreationCode = ""
    foreach ($folder in $persistFolders) {
        if ($folder -eq "user" -or $folder -eq "portable") {
            $folderCreationCode += @"

# Ensure $folder folder exists
if (-not (Test-Path "`$dir\$folder")) {
    New-Item -ItemType Directory -Path "`$dir\$folder" -Force | Out-Null
}
"@
        }
    }

    $preInstallScript = @"
$portableTxtCode$folderCreationCode
`$appDataPath = `$env:APPDATA
`$documentsPath = [Environment]::GetFolderPath('MyDocuments')

# Migrate application data from common locations
`$appDataPath, `$documentsPath | ForEach-Object {
    `$path = if (`$_ -eq `$appDataPath) { "`$appDataPath\$(($RepoInfo.Repo).ToLower())" } else { "`$documentsPath\$(($RepoInfo.Repo).ToLower())" }
    if (Test-Path `$path) {
        `$items = Get-ChildItem -Path `$path -Force
        if (`$items) {
            Write-Host "Migrating data from `$path"
            `$items | Copy-Item -Destination "`$dir\portable_data" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
"@
    $manifest["pre_install"] = $preInstallScript

    $checkverUrl = if ($RepoInfo.Platform -eq "github") {
        @{ "github" = $RepoInfo.RepoUrl }
    } else {
        @{ "gitlab" = $RepoInfo.RepoUrl }
    }
    $manifest["checkver"] = $checkverUrl

    # For nightly/dev builds, use static download URL (no $version substitution)
    if ($BuildType -eq "nightly" -or $BuildType -eq "dev") {
        $autoupdateUrl = $Asset.browser_download_url
    } else {
        $autoupdateUrl = $Asset.browser_download_url -replace [regex]::Escape($RepoInfo.Version), '$version'
    }

    # Determine hash config for autoupdate
    $hashConfig = $null
    if ($BuildType -eq "stable") {
        if ($RepoInfo.Platform -eq "github") {
            $assetName = Split-Path -Leaf $Asset.browser_download_url

            # Prefer API method for now since most releases don't have Windows-specific checksums
            # This will fetch the digest from the GitHub release API
            $hashConfig = [ordered]@{
                "url"      = "https://api.github.com/repos/$($RepoInfo.Owner)/$($RepoInfo.Repo)/releases/tags/`$version"
                "jsonpath" = "$.assets[?(@.name == '$assetName')].digest"
            }
        } else {
            # GitLab support
            $projectPath = "$($RepoInfo.Owner)%2F$($RepoInfo.Repo)"
            $assetName = Split-Path -Leaf $Asset.browser_download_url

            # Use GitLab API to fetch hash from release metadata
            $hashConfig = [ordered]@{
                "url"      = "https://gitlab.com/api/v4/projects/$projectPath/releases/`$version"
                "jsonpath" = "$.assets.sources[?(@.name == '$assetName')].digest"
            }
        }
    }    $autoupdateArch = [ordered]@{
        "url" = $autoupdateUrl
    }
    if ($hashConfig) {
        $autoupdateArch["hash"] = $hashConfig
    }

    $manifest["autoupdate"] = [ordered]@{
        "architecture" = [ordered]@{
            "64bit" = $autoupdateArch
        }
    }

    # Reorder manifest keys according to Scoop standard
    $orderedKeys = @(
        "version",
        "description",
        "homepage",
        "license",
        "notes",
        "depends",
        "suggest",
        "identifier",
        "url",
        "hash",
        "architecture",
        "extract_dir",
        "extract_to",
        "pre_install",
        "installer",
        "post_install",
        "env_add_path",
        "env_set",
        "bin",
        "shortcuts",
        "persist",
        "uninstaller",
        "checkver",
        "autoupdate",
        "64bit",
        "32bit",
        "arm64"
    )

    $orderedManifest = [ordered]@{}
    foreach ($key in $orderedKeys) {
        if ($manifest.Keys -contains $key) {
            $orderedManifest[$key] = $manifest[$key]
        }
    }

    # Add any remaining keys not in the standard order
    foreach ($key in $manifest.Keys) {
        if ($orderedManifest.Keys -notcontains $key) {
            $orderedManifest[$key] = $manifest[$key]
        }
    }

    return $orderedManifest
}

function Export-ManifestAsJson {
    param(
        [hashtable]$Manifest,
        [string]$RepoName,
        [string]$OutputDir
    )

    $jsonPath = Join-Path $OutputDir "$RepoName.json"

    # Manually build JSON in correct key order
    $lines = @("{")
    $keyOrder = @(
        "version",
        "description",
        "homepage",
        "license",
        "notes",
        "depends",
        "suggest",
        "identifier",
        "url",
        "hash",
        "architecture",
        "extract_dir",
        "extract_to",
        "pre_install",
        "installer",
        "post_install",
        "env_add_path",
        "env_set",
        "bin",
        "shortcuts",
        "persist",
        "uninstaller",
        "checkver",
        "autoupdate",
        "64bit",
        "32bit",
        "arm64"
    )

    $processedKeys = @()
    $allKeys = $Manifest.Keys

    # Process keys in order
    foreach ($key in $keyOrder) {
        if ($allKeys -contains $key) {
            $processedKeys += $key
            $value = $Manifest[$key]
            $jsonValue = ConvertTo-JsonValue -Value $value -Indent 2
            $lines += "  `"$key`": $jsonValue,"
        }
    }

    # Add any remaining keys not in standard order
    foreach ($key in $allKeys) {
        if ($processedKeys -notcontains $key) {
            $value = $Manifest[$key]
            $jsonValue = ConvertTo-JsonValue -Value $value -Indent 2
            $lines += "  `"$key`": $jsonValue,"
        }
    }

    # Remove trailing comma from last line
    $lines[-1] = $lines[-1] -replace ',$', ''
    $lines += "}"

    $json = $lines -join "`n"

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($jsonPath, $json + "`n", $utf8NoBom)

    Write-Host "[OK] Manifest saved to: $jsonPath" -ForegroundColor Green
    Write-Host "[INFO] Run 'npx prettier --write $RepoName.json' to format the JSON" -ForegroundColor Cyan

    return $jsonPath
}

function ConvertTo-JsonValue {
    param(
        [object]$Value,
        [int]$Indent = 0
    )

    $indentStr = " " * $Indent

    if ($Value -eq $null) {
        return "null"
    }

    if ($Value -is [string]) {
        # Escape special characters for JSON
        # Must do backslash first to avoid double-escaping
        $escaped = $Value.Replace('\', '\\')
        $escaped = $escaped.Replace('"', '\"')
        $escaped = $escaped.Replace("`r", '\r')
        $escaped = $escaped.Replace("`n", '\n')
        $escaped = $escaped.Replace("`t", '\t')
        # Note: backspace and form feed are rare in preinstall scripts, skip for now
        return "`"$escaped`""
    }

    if ($Value -is [bool]) {
        return if ($Value) { "true" } else { "false" }
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return $Value.ToString()
    }

    if ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return "[]"
        }

        # Check if it's a nested array (shortcuts case: array of arrays)
        # For shortcuts specifically, we need 2 strings as inner array
        if ($Value.Count -eq 2 -and $Value[0] -is [string] -and $Value[1] -is [string]) {
            # This is the shortcuts array [[exe, label]]
            $elem0 = ConvertTo-JsonValue -Value $Value[0] -Indent ($Indent + 4)
            $elem1 = ConvertTo-JsonValue -Value $Value[1] -Indent ($Indent + 4)
            return "[[`n    $elem0,`n    $elem1`n  ]]"
        }

        # Check if it's an array of arrays
        if ($Value[0] -is [array]) {
            $subItems = $Value | ForEach-Object {
                $item = $_
                $subIndent = " " * ($Indent + 4)
                if ($item -is [array]) {
                    $subElements = $item | ForEach-Object {
                        ConvertTo-JsonValue -Value $_ -Indent ($Indent + 8)
                    }
                    "$subIndent[`n$subIndent  $($subElements -join ",`n$subIndent  ")`n$subIndent]"
                } else {
                    "$subIndent$(ConvertTo-JsonValue -Value $item -Indent ($Indent + 4))"
                }
            }
            return "[`n$($subItems -join ",`n")`n$indentStr]"
        }

        # Regular array
        $items = $Value | ForEach-Object {
            "$indentStr  $(ConvertTo-JsonValue -Value $_ -Indent ($Indent + 2))"
        }
        return "[`n$($items -join ",`n")`n$indentStr]"
    }

    if ($Value -is [hashtable] -or $Value -is [System.Collections.Specialized.OrderedDictionary]) {
        if ($Value.Count -eq 0) {
            return "{}"
        }

        $subItems = @()
        foreach ($k in $Value.Keys) {
            $v = $Value[$k]
            $jsonVal = ConvertTo-JsonValue -Value $v -Indent ($Indent + 2)
            $subItems += "$indentStr  `"$k`": $jsonVal"
        }
        return "{`n$($subItems -join ",`n")`n$indentStr}"
    }

    return "`"$Value`""
}

# Main script
try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Scoop Manifest Creator" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $issueInfo = $null
    if ($IssueNumber) {
        Write-Host ""
        Write-Host "[STEP 0/7] Processing GitHub issue..." -ForegroundColor Magenta

        if (-not $GitHubToken) {
            throw "GitHubToken is required when using -IssueNumber. Provide a GitHub personal access token."
        }

        $issueInfo = Get-GitHubIssueInfo -IssueNumber $IssueNumber -Token $GitHubToken
        if ($issueInfo.RepoUrl -match 'github\.com') {
            $GitHubUrl = $issueInfo.RepoUrl
        } else {
            $GitLabUrl = $issueInfo.RepoUrl
        }

        Write-Host "[OK] Issue: $($issueInfo.IssueTitle)" -ForegroundColor Green
        Write-Host "[OK] Repository URL extracted: $($issueInfo.RepoUrl)" -ForegroundColor Green
    } else {
        if (-not $GitHubUrl -and -not $GitLabUrl) {
            throw "Either -GitHubUrl, -GitLabUrl, or -IssueNumber must be provided"
        }
    }

    Write-Host ""
    $stepNum = if ($issueInfo) { 1 } else { 1 }
    $totalSteps = if ($issueInfo) { 8 } else { 7 }
    Write-Host "[STEP $stepNum/$totalSteps] Fetching repository information..." -ForegroundColor Magenta

    if ($GitHubUrl) {
        $repoInfo = Get-GitHubRepoInfo -Url $GitHubUrl
    } else {
        $repoInfo = Get-GitLabRepoInfo -Url $GitLabUrl
    }

    Write-Host "[OK] Repository: $($repoInfo.Owner)/$($repoInfo.Repo)" -ForegroundColor Green
    Write-Host "[OK] Latest version: $($repoInfo.Version)" -ForegroundColor Green

    Write-Host ""
    Write-Host "[STEP $($stepNum + 1)/$totalSteps] Fetching repository metadata..." -ForegroundColor Magenta
    $metadata = Get-RepositoryMetadata -Owner $repoInfo.Owner -Repo $repoInfo.Repo -Platform $repoInfo.Platform

    Write-Host ""
    Write-Host "[STEP $($stepNum + 2)/$totalSteps] Finding Windows executable..." -ForegroundColor Magenta
    $asset = Find-WindowsExecutable -Assets $repoInfo.Assets
    Write-Host "[OK] Asset: $($asset.name) (Size: $([math]::Round($asset.size / 1MB, 2)) MB)" -ForegroundColor Green

    Write-Host ""
    Write-Host "[STEP $($stepNum + 3)/$totalSteps] Downloading and processing asset..." -ForegroundColor Magenta
    $tempDir = Join-Path $env:TEMP "manifest-creator-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    $downloadPath = Download-Asset -Asset $asset -OutputDir $tempDir

    $executablePath = $null
    $executableName = $null

    if ($asset.name -match '\.exe$') {
        $executablePath = $downloadPath
        $executableName = Split-Path -Leaf $downloadPath
    } else {
        $extractDir = Join-Path $tempDir "extracted"
        Extract-Archive -ArchivePath $downloadPath -ExtractDir $extractDir
        $executable = Find-ExecutableInDirectory -Directory $extractDir -ProjectName $repoInfo.Repo
        $executablePath = $executable.FullName
        $executableName = $executable.Name
    }

    Write-Host "[OK] Executable: $executableName" -ForegroundColor Green

    Write-Host ""
    $monitorStep = if ($issueInfo) { 5 } else { 5 }
    Write-Host "[STEP $monitorStep/$totalSteps] Monitoring application execution..." -ForegroundColor Magenta
    $persistResult = Monitor-ExecutableCreation -ExecutablePath $executablePath -WorkingDirectory (Split-Path $executablePath)

    Write-Host ""
    $buildStep = if ($issueInfo) { 6 } else { 6 }
    Write-Host "[STEP $buildStep/$totalSteps] Building manifest..." -ForegroundColor Magenta
    $platform = Detect-Platform -RepoName $repoInfo.Repo -Description $metadata.Description
    if ($platform) {
        Write-Host "[OK] Detected platform: $platform" -ForegroundColor Green
    } else {
        Write-Host "[INFO] Not an emulator, using repository description" -ForegroundColor Cyan
    }

    $asset | Add-Member -MemberType NoteProperty -Name 'FilePath' -Value $downloadPath

    $releaseChecksum = Get-ReleaseChecksum -Assets $repoInfo.Assets -TargetAssetName $asset.name
    if ($releaseChecksum) {
        Write-Host "[OK] Using checksum from release files" -ForegroundColor Green
        $asset | Add-Member -MemberType NoteProperty -Name 'Checksum' -Value $releaseChecksum -Force
        $asset | Add-Member -MemberType NoteProperty -Name 'HasChecksumFile' -Value $true -Force
    } else {
        Write-Host "[INFO] No checksum files found, calculating hash..." -ForegroundColor Cyan
        $calculatedHash = Calculate-FileHash -FilePath $downloadPath
        $asset | Add-Member -MemberType NoteProperty -Name 'Checksum' -Value $calculatedHash -Force
        $asset | Add-Member -MemberType NoteProperty -Name 'HasChecksumFile' -Value $false -Force
    }

    # Check if persist items were found and warn user if not
    $persistItemsToUse = $persistResult.Items
    if (-not $persistResult.HasPersist) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "WARNING - No Persist Folders Detected" -ForegroundColor Yellow
        Write-Host "========================================" -ForegroundColor Yellow
        Write-Host "The application was launched, but no data was saved to" -ForegroundColor Yellow
        Write-Host "the 'user' or 'portable' folders." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "This means:" -ForegroundColor Cyan
        Write-Host "  - Settings will NOT be preserved on updates" -ForegroundColor Yellow
        Write-Host "  - Save files and configs will be LOST" -ForegroundColor Yellow
        Write-Host "  - Each installation starts with default settings" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  1) Continue without persist (data loss risk)" -ForegroundColor Yellow
        Write-Host "  2) Re-run the application to capture configuration" -ForegroundColor Cyan
        Write-Host ""
        $choice = Read-Host "What would you like to do? (continue/rerun)"
        Write-Host ""

        if ($choice -eq "rerun" -or $choice -eq "2") {
            Write-Host "[INFO] Re-running executable for persist configuration..." -ForegroundColor Cyan
            $retryResult = Monitor-ExecutableCreation -ExecutablePath $executablePath -WorkingDirectory (Split-Path $executablePath)
            $persistItemsToUse = $retryResult.Items
            if ($retryResult.HasPersist) {
                Write-Host "[OK] Persist folders detected on retry" -ForegroundColor Green
            } else {
                Write-Host "[WARN] Still no persist folders. Continuing without persist." -ForegroundColor Yellow
            }
        } else {
            Write-Host "[INFO] Continuing without persist configuration" -ForegroundColor Cyan
        }
    }

    $manifest = Build-Manifest `
        -RepoInfo $repoInfo `
        -Asset $asset `
        -ExecutableName $executableName `
        -PersistItems $persistItemsToUse `
        -Metadata $metadata `
        -Platform $platform `
        -BuildType $repoInfo.BuildType `
        -UsesStandardFolders $usesStandardFolders

    $bucketDir = Join-Path (Split-Path $PSScriptRoot) "bucket"
    $manifestPath = Export-ManifestAsJson -Manifest $manifest -RepoName $repoInfo.Repo -OutputDir $bucketDir

    Write-Host ""
    Write-Host "[INFO] Cleaning up temporary files..." -ForegroundColor Cyan
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ""
    $validateStep = if ($issueInfo) { 7 } else { 7 }
    Write-Host "[STEP $validateStep/$totalSteps] Validating manifest with Scoop tools..." -ForegroundColor Magenta
    $checkInstallScript = Join-Path $PSScriptRoot "check-manifest-install.ps1"
    if (Test-Path $checkInstallScript) {
        Write-Host "[INFO] Running check-manifest-install test..." -ForegroundColor Cyan
        & $checkInstallScript -ManifestPath $manifestPath
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Manifest validation passed!" -ForegroundColor Green
        } else {
            Write-Host "[WARN] Manifest validation failed. Review the manifest and re-run tests." -ForegroundColor Yellow
        }
    } else {
        Write-Host "[INFO] check-manifest-install.ps1 not found, skipping validation test" -ForegroundColor Cyan
    }

    if ($issueInfo) {
        Write-Host ""
        $issueStep = if ($issueInfo) { 8 } else { 8 }
        Write-Host "[STEP $issueStep/$totalSteps] Updating GitHub issue..." -ForegroundColor Magenta

        $platformInfo = if ($platform) { "**Platform:** $platform" } else { "**Type:** Application" }

        $commentText = @"
✅ Manifest created successfully!

**Repository:** $($repoInfo.Owner)/$($repoInfo.Repo)
**Version:** $($repoInfo.Version)
$platformInfo
**Manifest:** \`bucket/$($repoInfo.Repo).json\`

The manifest has been automatically generated based on the latest release. The manifest has been validated with check-manifest-install. Please review and run validation tests:

\`\`\`powershell
.\bin\checkver.ps1 -Dir bucket -App $($repoInfo.Repo)
.\bin\check-autoupdate.ps1 -ManifestPath bucket\$($repoInfo.Repo).json
.\bin\check-manifest-install.ps1 -ManifestPath bucket\$($repoInfo.Repo).json
\`\`\`

If all tests pass, the manifest is ready for merging.
"@

        Update-GitHubIssue -IssueNumber $issueInfo.IssueNumber -Token $GitHubToken -Comment $commentText -Labels @("manifest-created")
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Manifest created successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Manifest Details:" -ForegroundColor Cyan
    Write-Host "  Repository: $($repoInfo.Owner)/$($repoInfo.Repo)"
    Write-Host "  Type: $(if ($platform) { "$platform Emulator" } else { "Application" })"
    Write-Host "  Version: $($repoInfo.Version)"
    Write-Host "  Location: $manifestPath"
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "1. Review the manifest: $manifestPath"
    Write-Host "2. Run validation tests:"
    Write-Host "   .\bin\checkver.ps1 -Dir bucket -App $($repoInfo.Repo)"
    Write-Host "   .\bin\check-autoupdate.ps1 -ManifestPath bucket\$($repoInfo.Repo).json"
    Write-Host "   .\bin\check-manifest-install.ps1 -ManifestPath bucket\$($repoInfo.Repo).json"
    if ($issueInfo) {
        Write-Host ""
        Write-Host "GitHub Issue: $($issueInfo.IssueUrl)" -ForegroundColor Cyan
    }

} catch {
    Write-Host ""
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Red

    if ($issueInfo -and $GitHubToken) {
        try {
            $errorComment = "❌ Failed to create manifest: $($_.Exception.Message)"
            Update-GitHubIssue -IssueNumber $issueInfo.IssueNumber -Token $GitHubToken -Comment $errorComment -Labels @("needs-investigation")
        } catch {
            Write-Host "[WARN] Could not update GitHub issue with error info" -ForegroundColor Yellow
        }
    }

    exit 1
}
