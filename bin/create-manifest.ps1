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

    $exeAsset = $null

    # Prefer .exe files
    $exeAssets = @($Assets | Where-Object { $_.name -match '\.exe$' -and $_.name -match 'windows|win|x64|x86_64' })
    if ($exeAssets.Count -gt 0) {
        $exeAsset = $exeAssets[0]
        Write-Host "[OK] Found Windows executable: $($exeAsset.name)" -ForegroundColor Green
        return $exeAsset
    }

    # Fall back to .zip files for Windows
    $zipAssets = @($Assets | Where-Object { $_.name -match '\.zip$' -and $_.name -match 'windows|win|x64|x86_64' })
    if ($zipAssets.Count -gt 0) {
        $zipAsset = $zipAssets[0]
        Write-Host "[OK] Found Windows ZIP archive: $($zipAsset.name)" -ForegroundColor Green
        return $zipAsset
    }

    throw "No suitable Windows executable or archive found in assets"
}

function Download-Asset {
    param(
        [object]$Asset,
        [string]$OutputDir
    )

    $ProgressPreference = 'SilentlyContinue'
    $downloadUrl = if ($Asset.browser_download_url) { $Asset.browser_download_url } else { $Asset.url }
    $fileName = $Asset.name
    $outputPath = Join-Path $OutputDir $fileName

    Write-Host "[INFO] Downloading: $fileName" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $downloadUrl -OutFile $outputPath -ErrorAction Stop
    Write-Host "[OK] Downloaded to: $outputPath" -ForegroundColor Green

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
    param([string]$Directory)

    $exes = @(Get-ChildItem -Path $Directory -Filter '*.exe' -Recurse | Select-Object -First 5)
    if ($exes.Count -eq 0) {
        throw "No executables found in extracted archive"
    }

    if ($exes.Count -eq 1) {
        Write-Host "[OK] Found executable: $($exes[0].Name)" -ForegroundColor Green
        return $exes[0]
    }

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

    Write-Host "[INFO] Monitoring for files/folders created during execution..." -ForegroundColor Cyan
    Write-Host "[INFO] Timeout: ${TimeoutSeconds}s (close the application to continue)" -ForegroundColor Cyan

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

    $persistItems = @()
    if ($createdItems.Count -gt 0) {
        Write-Host "[INFO] Found $($createdItems.Count) new items:" -ForegroundColor Cyan
        foreach ($item in $createdItems | Select-Object -First 10) {
            $relativePath = $item -replace [regex]::Escape($WorkingDirectory), '' -replace '^\\', ''
            Write-Host "  - $relativePath"
            $persistItems += $relativePath
        }

        if ($createdItems.Count -gt 10) {
            Write-Host "  ... and $($createdItems.Count - 10) more" -ForegroundColor Gray
        }
    }

    return $persistItems
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
        [string]$BuildType = "stable"
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

    # Only include hash for stable releases
    $hashValue = $null
    if ($BuildType -eq "stable") {
        $hashValue = "sha256:$($Asset.Checksum)"
    }
    # For nightly/dev, don't include hash (Scoop skips verification)

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

    $manifest["post_install"] = @(
        "Add-Content -Path `"`$dir\portable.txt`" -Value '' -Encoding UTF8"
    )

    $manifest["bin"] = $ExecutableName

    $manifest["shortcuts"] = @(
        @($ExecutableName, (if ($Platform) { "$Platform [app]" } else { $ExecutableName }))
    )

    $persistArray = @("portable_data")
    if ($PersistItems.Count -gt 0) {
        $persistArray += $PersistItems | Select-Object -Unique
    }
    $manifest["persist"] = $persistArray

    $preInstallScript = @"
`$appDataPath = `$env:APPDATA
`$documentsPath = [Environment]::GetFolderPath('MyDocuments')

# Migrate application data from common locations
@(
    "`$appDataPath\$(($RepoInfo.Repo).ToLower())",
    "`$documentsPath\$(($RepoInfo.Repo).ToLower())"
) | ForEach-Object {
    if (Test-Path `$_) {
        `$items = Get-ChildItem -Path `$_ -Force
        if (`$items) {
            Write-Host "Migrating data from `$_"
            `$items | Copy-Item -Destination `"`$dir\portable_data`" -Recurse -Force -ErrorAction SilentlyContinue
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

    # Determine hash config
    $hashConfig = $null
    if ($BuildType -eq "stable") {
        if ($Asset.HasChecksumFile) {
            if ($RepoInfo.Platform -eq "github") {
                $hashConfig = [ordered]@{
                    "url"      = "https://api.github.com/repos/$($RepoInfo.Owner)/$($RepoInfo.Repo)/releases/latest"
                    "jsonpath" = "`$.assets[?(@.name == '$(Split-Path -Leaf $Asset.browser_download_url)')].digest"
                }
            } else {
                $projectPath = "$($RepoInfo.Owner)%2F$($RepoInfo.Repo)"
                $hashConfig = [ordered]@{
                    "url"      = "https://gitlab.com/api/v4/projects/$projectPath/releases"
                    "jsonpath" = "`$[0].assets.sources[?(@.name == '$(Split-Path -Leaf $Asset.browser_download_url)')].digest"
                }
            }
        } else {
            $hashConfig = "sha256|$($Asset.Checksum)"
        }
    }

    $autoupdateArch = [ordered]@{
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

    return $manifest
}

function Export-ManifestAsJson {
    param(
        [hashtable]$Manifest,
        [string]$RepoName,
        [string]$OutputDir
    )

    $jsonPath = Join-Path $OutputDir "$RepoName.json"

    $json = $Manifest | ConvertTo-Json -Depth 10

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($jsonPath, $json + "`n", $utf8NoBom)

    Write-Host "[OK] Manifest saved to: $jsonPath" -ForegroundColor Green
    return $jsonPath
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
    $totalSteps = if ($issueInfo) { 7 } else { 6 }
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
        $executable = Find-ExecutableInDirectory -Directory $extractDir
        $executablePath = $executable.FullName
        $executableName = $executable.Name
    }

    Write-Host "[OK] Executable: $executableName" -ForegroundColor Green

    Write-Host ""
    $monitorStep = if ($issueInfo) { 5 } else { 5 }
    Write-Host "[STEP $monitorStep/$totalSteps] Monitoring application execution..." -ForegroundColor Magenta
    $persistItems = Monitor-ExecutableCreation -ExecutablePath $executablePath -WorkingDirectory (Split-Path $executablePath)

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

    $manifest = Build-Manifest `
        -RepoInfo $repoInfo `
        -Asset $asset `
        -ExecutableName $executableName `
        -PersistItems $persistItems `
        -Metadata $metadata `
        -Platform $platform `
        -BuildType $repoInfo.BuildType

    $bucketDir = Join-Path (Split-Path $PSScriptRoot) "bucket"
    $manifestPath = Export-ManifestAsJson -Manifest $manifest -RepoName $repoInfo.Repo -OutputDir $bucketDir

    Write-Host ""
    Write-Host "[INFO] Cleaning up temporary files..." -ForegroundColor Cyan
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($issueInfo) {
        Write-Host ""
        Write-Host "[STEP 7/$totalSteps] Updating GitHub issue..." -ForegroundColor Magenta

        $platformInfo = if ($platform) { "**Platform:** $platform" } else { "**Type:** Application" }

        $commentText = @"
✅ Manifest created successfully!

**Repository:** $($repoInfo.Owner)/$($repoInfo.Repo)
**Version:** $($repoInfo.Version)
$platformInfo
**Manifest:** \`bucket/$($repoInfo.Repo).json\`

The manifest has been automatically generated based on the latest release. Please review and run validation tests:

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
