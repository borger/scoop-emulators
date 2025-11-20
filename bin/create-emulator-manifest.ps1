param(
    [Parameter(Mandatory = $false)]
    [string]$GitHubUrl,

    [Parameter(Mandatory = $false)]
    [string]$IssueNumber,

    [Parameter(Mandatory = $false)]
    [string]$GitHubToken,

    [switch]$AutoApprove
)

$ErrorActionPreference = 'Stop'

# Verify at least one input method is provided
if (-not $GitHubUrl -and -not $IssueNumber) {
    Write-Host "Usage:" -ForegroundColor Cyan
    Write-Host "  Create from direct URL:"
    Write-Host "    .\create-emulator-manifest.ps1 -GitHubUrl 'https://github.com/owner/repo'"
    Write-Host ""
    Write-Host "  Create from GitHub issue:"
    Write-Host "    .\create-emulator-manifest.ps1 -IssueNumber 123 -GitHubToken 'ghp_xxx' [-AutoApprove]"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  -GitHubUrl    : GitHub repository URL"
    Write-Host "  -IssueNumber  : GitHub issue number in this repository"
    Write-Host "  -GitHubToken  : GitHub personal access token (required for issues)"
    Write-Host "  -AutoApprove  : Skip confirmation prompts"
    exit 0
}

# Helper functions
function Get-GitHubRepoInfo {
    param([string]$Url)

    $match = $Url -match 'github\.com/([^/]+)/([^/]+)/?$'
    if (-not $match) {
        throw "Invalid GitHub URL format. Expected: https://github.com/owner/repo"
    }

    $owner = $matches[1]
    $repo = $matches[2]

    $apiUrl = "https://api.github.com/repos/$owner/$repo/releases/latest"
    Write-Host "[INFO] Fetching release info from: $apiUrl" -ForegroundColor Cyan

    $response = Invoke-WebRequest -Uri $apiUrl -ErrorAction Stop
    $releaseInfo = $response.Content | ConvertFrom-Json

    return @{
        Owner       = $owner
        Repo        = $repo
        TagName     = $releaseInfo.tag_name
        Version     = $releaseInfo.tag_name -replace '^v', ''
        Assets      = $releaseInfo.assets
        RepoUrl     = $Url
        License     = $null
        Description = $null
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

        # Extract GitHub URL from issue body
        $urlMatch = $issueInfo.body -match 'https?://github\.com/[^/]+/[^/\s)]+'
        if (-not $urlMatch) {
            throw "No GitHub repository URL found in issue body"
        }

        $repoUrl = $matches[0]
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

    # Add labels and close
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
    param([string]$Owner, [string]$Repo)

    $apiUrl = "https://api.github.com/repos/$owner/$repo"
    Write-Host "[INFO] Fetching repository metadata..." -ForegroundColor Cyan

    $response = Invoke-WebRequest -Uri $apiUrl -ErrorAction Stop
    $repoInfo = $response.Content | ConvertFrom-Json

    $metadata = @{
        Description = $repoInfo.description
        License     = $repoInfo.license.spdx_id
        LicenseUrl  = if ($repoInfo.license) { "https://raw.githubusercontent.com/$owner/$repo/main/LICENSE" } else { $null }
    }

    return $metadata
}

function Find-WindowsExecutable {
    param([System.Collections.Generic.List[object]]$Assets)

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
    $downloadUrl = $Asset.browser_download_url
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

    $platformMap = @{
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

    foreach ($pattern in $platformMap.Keys) {
        if ($searchText -match $pattern) {
            return $platformMap[$pattern]
        }
    }

    return "Unknown"
}

function Get-ReleaseChecksum {
    param(
        [object[]]$Assets,
        [string]$TargetAssetName,
        [string]$DownloadUrl = $null
    )

    # Strategy 1: Look for checksum files in release assets
    $checksumPatterns = @('*.sha256', '*.sha256sum', '*.sha256.txt', '*.checksum', '*.hashes', '*.DIGEST', '*.md5', '*.md5sum')
    $checksumAssets = @()

    foreach ($pattern in $checksumPatterns) {
        $checksumAssets += @($Assets | Where-Object { $_.name -like $pattern })
    }

    if ($checksumAssets.Count -gt 0) {
        # Download and parse the checksum file
        foreach ($checksumAsset in $checksumAssets) {
            try {
                $ProgressPreference = 'SilentlyContinue'
                $tempFile = Join-Path $env:TEMP "checksum-$(Get-Random).txt"
                Invoke-WebRequest -Uri $checksumAsset.browser_download_url -OutFile $tempFile -ErrorAction Stop

                # Parse the checksum file
                $content = Get-Content -Path $tempFile -Raw
                $lines = $content -split "`n" | Where-Object { $_ -match '\S' }

                foreach ($line in $lines) {
                    # Match common formats: "hash filename" or "filename hash"
                    if ($line -match '^([a-f0-9]{64})\s+(.+?)$' -or $line -match '^(.+?)\s+([a-f0-9]{64})$') {
                        $hash = if ($matches[1] -match '^[a-f0-9]{64}$') { $matches[1] } else { $matches[2] }
                        $filename = if ($matches[1] -match '^[a-f0-9]{64}$') { $matches[2] } else { $matches[1] }

                        # Check if this matches the target asset
                        if ($filename -like "*$($TargetAssetName)*" -or $TargetAssetName -like "*$filename*") {
                            Write-Host "[OK] Found SHA256 from GitHub release: $hash" -ForegroundColor Green
                            Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
                            return $hash
                        }
                    }
                }
                Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Host "[WARN] Failed to parse checksum file $($checksumAsset.name): $_" -ForegroundColor Yellow
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

        # Wait for process or timeout
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

    # Compare snapshots
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
        [string]$Platform
    )

    $manifest = [ordered]@{
        "version"     = $RepoInfo.Version
        "description" = "$Platform Emulator"
        "homepage"    = $RepoInfo.RepoUrl
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

    $architecture = [ordered]@{
        "64bit" = [ordered]@{
            "url"  = $Asset.browser_download_url
            "hash" = "sha256:$($Asset.Checksum)"
        }
    }
    $manifest["architecture"] = $architecture

    $manifest["post_install"] = @(
        "Add-Content -Path `"`$dir\portable.txt`" -Value '' -Encoding UTF8"
    )

    $manifest["bin"] = $ExecutableName

    # Create shortcuts based on platform
    $shortcutName = "$Platform [emu]"
    $shortcutArray = @(
        @($ExecutableName, $shortcutName)
    )
    $manifest["shortcuts"] = $shortcutArray

    # Add persist items
    $persistArray = @("portable_data")
    if ($PersistItems.Count -gt 0) {
        $persistArray += $PersistItems | Select-Object -Unique
    }
    $manifest["persist"] = $persistArray

    # Add pre_install for data migration
    $preInstallScript = @"
`$appDataPath = `$env:APPDATA
`$documentsPath = [Environment]::GetFolderPath('MyDocuments')

# Migrate emulator data from common locations
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

    $manifest["checkver"] = [ordered]@{
        "github" = $RepoInfo.RepoUrl
    }

    # Build autoupdate with hash URL if checksum files exist in release, otherwise use calculated hash
    $autoupdateUrl = $Asset.browser_download_url -replace $RepoInfo.Version, '$version'

    $hashConfig = $null
    if ($Asset.HasChecksumFile) {
        # Use Scoop's API-based hash retrieval
        $hashConfig = [ordered]@{
            "url"      = "https://api.github.com/repos/$($RepoInfo.Owner)/$($RepoInfo.Repo)/releases/latest"
            "jsonpath" = "`$.assets[?(@.name == '$(Split-Path -Leaf $Asset.browser_download_url)')].digest"
        }
    } else {
        # Use static calculated hash
        $hashConfig = "sha256|$($Asset.Checksum)"
    }

    $manifest["autoupdate"] = [ordered]@{
        "architecture" = [ordered]@{
            "64bit" = [ordered]@{
                "url"  = $autoupdateUrl
                "hash" = $hashConfig
            }
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

    # Convert to JSON with proper formatting
    $json = $Manifest | ConvertTo-Json -Depth 10

    # Write with UTF-8 without BOM
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($jsonPath, $json + "`n", $utf8NoBom)

    Write-Host "[OK] Manifest saved to: $jsonPath" -ForegroundColor Green
    return $jsonPath
}

# Main script
try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Emulator Manifest Creator" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # Step 0: Determine input source (direct URL or GitHub issue)
    $issueInfo = $null
    if ($IssueNumber) {
        Write-Host ""
        Write-Host "[STEP 0/7] Processing GitHub issue..." -ForegroundColor Magenta

        if (-not $GitHubToken) {
            throw "GitHubToken is required when using -IssueNumber. Provide a GitHub personal access token."
        }

        $issueInfo = Get-GitHubIssueInfo -IssueNumber $IssueNumber -Token $GitHubToken
        $GitHubUrl = $issueInfo.RepoUrl

        Write-Host "[OK] Issue: $($issueInfo.IssueTitle)" -ForegroundColor Green
        Write-Host "[OK] Repository URL extracted: $GitHubUrl" -ForegroundColor Green
    } else {
        if (-not $GitHubUrl) {
            throw "Either -GitHubUrl or -IssueNumber must be provided"
        }
    }

    # Step 1: Get GitHub repo info
    Write-Host ""
    $stepNum = if ($issueInfo) { 1 } else { 1 }
    $totalSteps = if ($issueInfo) { 7 } else { 6 }
    Write-Host "[STEP $stepNum/$totalSteps] Fetching GitHub repository information..." -ForegroundColor Magenta
    $repoInfo = Get-GitHubRepoInfo -Url $GitHubUrl
    Write-Host "[OK] Repository: $($repoInfo.Owner)/$($repoInfo.Repo)" -ForegroundColor Green
    Write-Host "[OK] Latest version: $($repoInfo.Version)" -ForegroundColor Green

    # Step 2: Get repository metadata (license, description)
    Write-Host ""
    Write-Host "[STEP $($stepNum + 1)/$totalSteps] Fetching repository metadata..." -ForegroundColor Magenta
    $metadata = Get-RepositoryMetadata -Owner $repoInfo.Owner -Repo $repoInfo.Repo

    # Step 3: Find Windows executable/archive
    Write-Host ""
    Write-Host "[STEP $($stepNum + 2)/$totalSteps] Finding Windows executable..." -ForegroundColor Magenta
    $asset = Find-WindowsExecutable -Assets $repoInfo.Assets
    Write-Host "[OK] Asset: $($asset.name) (Size: $([math]::Round($asset.size / 1MB, 2)) MB)" -ForegroundColor Green

    # Step 4: Download and process asset
    Write-Host ""
    Write-Host "[STEP $($stepNum + 3)/$totalSteps] Downloading and processing asset..." -ForegroundColor Magenta
    $tempDir = Join-Path $env:TEMP "emulator-manifest-$(Get-Random)"
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

    # Step 5: Monitor executable execution
    Write-Host ""
    $monitorStep = if ($issueInfo) { 5 } else { 5 }
    Write-Host "[STEP $monitorStep/$totalSteps] Monitoring application execution..." -ForegroundColor Magenta
    $persistItems = Monitor-ExecutableCreation -ExecutablePath $executablePath -WorkingDirectory (Split-Path $executablePath)

    # Step 6: Detect platform and build manifest
    Write-Host ""
    $buildStep = if ($issueInfo) { 6 } else { 6 }
    Write-Host "[STEP $buildStep/$totalSteps] Building manifest..." -ForegroundColor Magenta
    $platform = Detect-Platform -RepoName $repoInfo.Repo -Description $metadata.Description
    Write-Host "[OK] Detected platform: $platform" -ForegroundColor Green

    # Add file path to asset for hash calculation
    $asset | Add-Member -MemberType NoteProperty -Name 'FilePath' -Value $downloadPath

    # Try to get checksum from GitHub release files first
    $releaseChecksum = Get-ReleaseChecksum -Assets $repoInfo.Assets -TargetAssetName $asset.name
    if ($releaseChecksum) {
        Write-Host "[OK] Using checksum from GitHub release files" -ForegroundColor Green
        $asset | Add-Member -MemberType NoteProperty -Name 'Checksum' -Value $releaseChecksum -Force
        $asset | Add-Member -MemberType NoteProperty -Name 'HasChecksumFile' -Value $true -Force
    } else {
        Write-Host "[INFO] No checksum files found in release, calculating hash..." -ForegroundColor Cyan
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
        -Platform $platform

    # Export manifest
    $bucketDir = Join-Path (Split-Path $PSScriptRoot) "bucket"
    $manifestPath = Export-ManifestAsJson -Manifest $manifest -RepoName $repoInfo.Repo -OutputDir $bucketDir

    # Cleanup
    Write-Host ""
    Write-Host "[INFO] Cleaning up temporary files..." -ForegroundColor Cyan
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    # Step 7: Update GitHub issue if applicable
    if ($issueInfo) {
        Write-Host ""
        Write-Host "[STEP 7/$totalSteps] Updating GitHub issue..." -ForegroundColor Magenta

        $commentText = @"
✅ Manifest created successfully!

**Repository:** $($repoInfo.Owner)/$($repoInfo.Repo)
**Version:** $($repoInfo.Version)
**Platform:** $platform
**Manifest:** \`bucket/$($repoInfo.Repo).json\`

The manifest has been automatically generated based on the latest release. Please review and run validation tests:

\`\`\`powershell
.\bin\checkver.ps1 -Dir bucket -App $($repoInfo.Repo)
.\bin\check-autoupdate.ps1 -ManifestPath bucket\$($repoInfo.Repo).json
.\bin\check-manifest-install.ps1 -ManifestPath bucket\$($repoInfo.Repo).json
\`\`\`

If all tests pass, the manifest is ready for merging.
"@

        Update-GitHubIssue -IssueNumber $issueInfo.IssueNumber -Token $GitHubToken -Comment $commentText -Labels @("emulator-added")
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Manifest created successfully!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Manifest Details:" -ForegroundColor Cyan
    Write-Host "  Repository: $($repoInfo.Owner)/$($repoInfo.Repo)"
    Write-Host "  Platform: $platform"
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

    # Try to update issue with error info if applicable
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
