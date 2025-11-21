#Requires -Version 5.1
<#
.SYNOPSIS
Automatically generates Scoop manifest files from GitHub, GitLab, or SourceForge releases.

.DESCRIPTION
Creates valid Scoop manifest JSON files from latest releases.
Auto-detects platforms (emulators), handles stable/nightly/dev builds,
configures portable mode, and integrates with GitHub issues.

.PARAMETER RepoUrl
Repository URL (GitHub, GitLab, or SourceForge)

.PARAMETER IssueNumber
GitHub issue number for auto-integration

.PARAMETER GitHubToken
GitHub personal access token (required for -IssueNumber)

.EXAMPLE
.\create-manifest.ps1 -RepoUrl 'https://github.com/owner/repo'
.\create-manifest.ps1 -RepoUrl 'https://sourceforge.net/projects/projectname'
.\create-manifest.ps1 -IssueNumber 123 -GitHubToken 'ghp_xxx'
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$RepoUrl,

    [Parameter(Mandatory = $false)]
    [int]$IssueNumber,

    [Parameter(Mandatory = $false)]
    [string]$GitHubToken,

    [Parameter(Mandatory = $false)]
    [string]$Description,

    [Parameter(Mandatory = $false)]
    [string[]]$PersistFolders,

    [Parameter(Mandatory = $false)]
    [string]$ShortcutName,

    [Parameter(Mandatory = $false)]
    [switch]$NonInteractive,

    [Parameter(Mandatory = $false)]
    [switch]$CreatePR
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# Set security protocol for all web requests
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Helper function for colored output (maintains Write-Host functionality with warning suppression)
function Write-Status {
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        [string]$Message = '',

        [ValidateSet('Info', 'OK', 'Warn', 'Error', 'Step')]
        [string]$Level = 'Info'
    )

    $colorMap = @{
        'Info'  = 'Cyan'
        'OK'    = 'Green'
        'Warn'  = 'Yellow'
        'Error' = 'Red'
        'Step'  = 'Magenta'
    }

    [System.Console]::ForegroundColor = $colorMap[$Level]
    [System.Console]::Out.WriteLine($Message)
    [System.Console]::ResetColor()
}

Test-Prerequisites

function Get-NonInteractivePreference {
    <#
    .SYNOPSIS
    Determines whether the current session should run in non-interactive mode.
    #>
    [CmdletBinding()]
    param([switch]$Override)

    return $Override.IsPresent -or ([Environment]::GetEnvironmentVariable('PSNonInteractive') -eq 'true') -or -not [Environment]::UserInteractive
}

function Request-ManifestDetails {
    [CmdletBinding()]
    param(
        [hashtable]$Manifest,
        [array]$CurrentPersistItems,
        [string]$ProvidedDescription,
        [string[]]$ProvidedPersistFolders,
        [string]$ProvidedShortcutName,
        [bool]$IsNonInteractive = $false
    )

    # Use provided values if given, otherwise use defaults
    $finalDesc = if ($ProvidedDescription) { $ProvidedDescription } else { $Manifest['description'] }
    $finalShortcut = if ($ProvidedShortcutName) { $ProvidedShortcutName } else { $Manifest['shortcuts'][0][1] }

    # If user provided persist folders, use only those; otherwise use detected items
    if ($ProvidedPersistFolders -and $ProvidedPersistFolders.Count -gt 0) {
        $finalPersist = @($ProvidedPersistFolders) | Select-Object -Unique
    } else {
        $finalPersist = @($CurrentPersistItems) | Select-Object -Unique
    }
    $finalPersist = @($finalPersist) | Where-Object { $_ }

    return @{
        Description  = $finalDesc
        PersistItems = $finalPersist
        ShortcutName = $finalShortcut
    }
}

#region Validation Functions

function Test-RepoUrl {
    [CmdletBinding()]
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }

    # Allow GitHub (including releases/tags), GitLab, SourceForge
    if ($Url -match 'github\.com/[^/]+/[^/]+') { return $true }
    if ($Url -match 'gitlab\.com/[^/]+/[^/]+') { return $true }
    if ($Url -match 'sourceforge\.net/projects/[^/]+') { return $true }

    return $false
}

function Test-NightlyBuild {
    [CmdletBinding()]
    param([string]$TagName)

    $nightlyPatterns = @('nightly', 'continuous', 'dev', 'latest', 'main', 'master', 'trunk', 'canary')
    return $nightlyPatterns -contains ($TagName.ToLower())
}

function Resolve-CommitVersion {
    <#
    .SYNOPSIS
    Resolves a commit hash for nightly/dev builds regardless of whether the release references a branch or explicit SHA.
    #>
    [CmdletBinding()]
    param(
        [string]$Owner,
        [string]$Repo,
        [string]$TargetCommitish
    )

    if (-not $TargetCommitish) {
        return $null
    }

    $trimmed = $TargetCommitish.Trim()
    if (-not $trimmed) {
        return $null
    }

    $isHash = $trimmed -match '^[0-9a-f]{7,}$'
    if ($isHash) {
        $shortHash = if ($trimmed.Length -gt 7) { $trimmed.Substring(0, 7) } else { $trimmed }
        "Using commit hash as version: $shortHash" | Write-Status -Level OK
        return @{ Short = $shortHash; Full = $trimmed }
    }

    try {
        $branchUrl = "https://api.github.com/repos/$Owner/$Repo/branches/$trimmed"
        $branchInfo = Invoke-RestMethod -Uri $branchUrl -ErrorAction Stop
        if ($branchInfo.commit.sha) {
            $resolved = $branchInfo.commit.sha
            $shortHash = $resolved.Substring(0, 7)
            "Using commit hash from branch ($trimmed): $shortHash" | Write-Status -Level OK
            return @{ Short = $shortHash; Full = $resolved }
        }
    } catch {
        'Could not fetch branch commit, using tag name' | Write-Status -Level Warn
    }

    return $null
}

#endregion

#region API Functions

function Get-GitHubReleaseInfo {
    [CmdletBinding()]
    param([string]$Url)

    $match = $Url -match 'github\.com/([^/]+)/([^/?]+)'
    if (-not $match) {
        throw 'Invalid GitHub URL format. Expected: https://github.com/owner/repo'
    }

    $owner = $matches[1]
    $repo = $matches[2]

    $tagMatch = $Url -match '/releases/tag/([^/?]+)'
    if ($tagMatch) {
        $tagName = $matches[1]
        $apiUrl = "https://api.github.com/repos/$owner/$repo/releases/tags/$tagName"
        "Fetching release info for tag: $tagName" | Write-Status -Level Info
    } else {
        $apiUrl = "https://api.github.com/repos/$owner/$repo/releases/latest"
        "Fetching latest release info from: $apiUrl" | Write-Status -Level Info
    }

    try {
        $releaseInfo = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop
    } catch {
        if ($_.Exception.Response.StatusCode -eq 'NotFound') {
            # Fallback: Try to get tags if latest release fails (common in pre-release only repos)
            "Latest release not found, checking tags..." | Write-Status -Level Warn
            $tagsUrl = "https://api.github.com/repos/$owner/$repo/tags"
            $tags = Invoke-RestMethod -Uri $tagsUrl -ErrorAction Stop
            if ($tags.Count -gt 0) {
                $latestTag = $tags[0]
                "Found latest tag: $($latestTag.name)" | Write-Status -Level Info
                # We need release info for assets, so try to get release by tag
                $apiUrl = "https://api.github.com/repos/$owner/$repo/releases/tags/$($latestTag.name)"
                $releaseInfo = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop
            } else {
                throw "No releases or tags found for $owner/$repo"
            }
        } else {
            throw $_
        }
    }

    $buildType = 'stable'
    $versionToUse = $releaseInfo.tag_name -replace '^v', ''
    $resolvedCommitHash = $releaseInfo.target_commitish

    if (Test-NightlyBuild -TagName $releaseInfo.tag_name) {
        $buildType = 'nightly'
        'Detected nightly/continuous build' | Write-Status -Level OK
        $commitInfo = Resolve-CommitVersion -Owner $owner -Repo $repo -TargetCommitish $releaseInfo.target_commitish
        if ($commitInfo) {
            $versionToUse = $commitInfo.Short
            $resolvedCommitHash = $commitInfo.Full
        }
    } elseif ($releaseInfo.prerelease) {
        $buildType = 'dev'
        'Detected pre-release build' | Write-Status -Level OK
        $commitInfo = Resolve-CommitVersion -Owner $owner -Repo $repo -TargetCommitish $releaseInfo.target_commitish
        if ($commitInfo) {
            $versionToUse = $commitInfo.Short
            $resolvedCommitHash = $commitInfo.Full
        }
    }

    return @{
        Owner        = $owner
        Repo         = $repo
        TagName      = $releaseInfo.tag_name
        Version      = $versionToUse
        Assets       = $releaseInfo.assets
        RepoUrl      = "https://github.com/$owner/$repo"
        Platform     = 'github'
        BuildType    = $buildType
        IsPrerelease = $releaseInfo.prerelease
        License      = $null
        Description  = $null
        CommitHash   = if ($resolvedCommitHash) { $resolvedCommitHash } else { $null }
        TargetRef    = $releaseInfo.target_commitish
    }
}

function Get-GitLabReleaseInfo {
    [CmdletBinding()]
    param([string]$Url)

    $match = $Url -match 'gitlab\.com/([^/]+)/([^/]+)/?$'
    if (-not $match) {
        throw 'Invalid GitLab URL format. Expected: https://gitlab.com/owner/repo'
    }

    $owner = $matches[1]
    $repo = $matches[2]

    $apiUrl = "https://gitlab.com/api/v4/projects/$owner%2F$repo/releases"
    "Fetching release info from: $apiUrl" | Write-Status -Level Info

    $releases = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop

    if ($releases.Count -eq 0) {
        throw 'No releases found in GitLab repository'
    }

    $latestRelease = $releases[0]
    $assets = @()
    if ($latestRelease.assets.sources) {
        $assets = $latestRelease.assets.sources
    }
    # GitLab releases also have 'links' which are often binaries
    if ($latestRelease.assets.links) {
        $assets += $latestRelease.assets.links
    }

    $buildType = 'stable'
    $versionToUse = $latestRelease.tag_name -replace '^v', ''
    $commitHash = $null

    if (Test-NightlyBuild -TagName $latestRelease.tag_name) {
        $buildType = 'nightly'
        'Detected nightly/continuous build' | Write-Status -Level OK

        if ($latestRelease.commit) {
            $commitHash = $latestRelease.commit.id
            $shortHash = $latestRelease.commit.short_id
            $versionToUse = $shortHash
            "Using commit hash from GitLab release: $shortHash" | Write-Status -Level OK
        }
    }

    return @{
        Owner       = $owner
        Repo        = $repo
        TagName     = $latestRelease.tag_name
        Version     = $versionToUse
        Assets      = $assets
        RepoUrl     = $Url
        Platform    = 'gitlab'
        BuildType   = $buildType
        License     = $null
        Description = $latestRelease.description
        CommitHash  = $commitHash
    }
}

function Get-SourceForgeReleaseInfo {
    [CmdletBinding()]
    param(
        [string]$Url,
        [switch]$NonInteractive
    )

    $match = $Url -match 'sourceforge\.net/projects/([^/]+)'
    if (-not $match) {
        throw 'Invalid SourceForge URL format. Expected: https://sourceforge.net/projects/projectname'
    }

    $project = $matches[1]
    $apiUrl = "https://sourceforge.net/projects/$project/best_release.json"
    "Fetching release info from: $apiUrl" | Write-Status -Level Info

    $releaseInfo = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop

    $filename = $releaseInfo.release.filename
    $version = $null

    # Try to extract version from filename
    if ($filename -match '[-_]v?(\d+\.\d+(\.\d+)?([-_][a-zA-Z0-9]+)?)') {
        $version = $matches[1]
    } else {
        # Fallback to user input if interactive
        if (-not $NonInteractive) {
            "Could not auto-detect version from filename: $filename" | Write-Status -Level Warn
            do {
                $version = Read-Host "Please enter the version number manually"
                if ([string]::IsNullOrWhiteSpace($version)) {
                    "Version cannot be empty." | Write-Status -Level Warn
                }
            } until (-not [string]::IsNullOrWhiteSpace($version))
        }

        if (-not $version) {
            throw "Could not extract version from SourceForge filename: $filename"
        }
    }

    return @{
        Owner       = $project
        Repo        = $project
        TagName     = $version
        Version     = $version
        Assets      = @(@{
                name                 = $filename
                url                  = $releaseInfo.release.url
                browser_download_url = $releaseInfo.release.url
            })
        RepoUrl     = $Url
        Platform    = 'sourceforge'
        License     = $null
        Description = "SourceForge project $project"
    }
}

function Get-IssueMetadata {
    [CmdletBinding()]
    param(
        [int]$IssueNumber,
        [string]$Token
    )

    $bucketOwner = 'borger'
    $bucketRepo = 'scoop-emulators'
    $apiUrl = "https://api.github.com/repos/$bucketOwner/$bucketRepo/issues/$IssueNumber"

    "Fetching issue #$IssueNumber..." | Write-Status -Level Info

    $headers = @{
        'Authorization' = "token $Token"
        'Accept'        = 'application/vnd.github.v3+json'
    }

    try {
        $issueInfo = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop

        if ($issueInfo.body -match 'https?://github\.com/([^/]+)/([^/\s)]+)') {
            $repoUrl = $matches[0]
        } elseif ($issueInfo.body -match 'https?://gitlab\.com/([^/]+)/([^/\s)]+)') {
            $repoUrl = $matches[0]
        } elseif ($issueInfo.body -match 'https?://sourceforge\.net/projects/([^/\s)]+)') {
            $repoUrl = $matches[0]
        } else {
            throw 'No supported repository URL found in issue body'
        }

        "Found repository URL: $repoUrl" | Write-Status -Level OK

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

function Update-IssueComment {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [int]$IssueNumber,
        [string]$Token,
        [string]$Comment,
        [string[]]$Labels = @()
    )

    if (-not $PSCmdlet.ShouldProcess("Issue #$IssueNumber", 'Update')) {
        return
    }

    $bucketOwner = 'borger'
    $bucketRepo = 'scoop-emulators'
    $apiUrl = "https://api.github.com/repos/$bucketOwner/$bucketRepo/issues/$IssueNumber"

    $headers = @{
        'Authorization' = "token $Token"
        'Accept'        = 'application/vnd.github.v3+json'
    }

    if ($Comment) {
        $commentUrl = "$apiUrl/comments"
        $body = @{ body = $Comment } | ConvertTo-Json

        try {
            Invoke-RestMethod -Uri $commentUrl -Headers $headers -Method Post -Body $body -ContentType 'application/json' | Out-Null
            "Added comment to issue #$IssueNumber" | Write-Status -Level OK
        } catch {
            "Failed to add comment: $_" | Write-Status -Level Warn
        }
    }

    if ($Labels.Count -gt 0) {
        $labelBody = @{ labels = $Labels } | ConvertTo-Json

        try {
            Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Patch -Body $labelBody -ContentType 'application/json' | Out-Null
            'Updated issue labels' | Write-Status -Level OK
        } catch {
            "Failed to update labels: $_" | Write-Status -Level Warn
        }
    }
}

function Get-RepositoryInfo {
    [CmdletBinding()]
    param(
        [string]$Owner,
        [string]$Repo,
        [ValidateSet('github', 'gitlab', 'sourceforge')]
        [string]$Platform = 'github'
    )

    if ($Platform -eq 'github') {
        $apiUrl = "https://api.github.com/repos/$owner/$repo"
        'Fetching repository metadata...' | Write-Status -Level Info

        $repoInfo = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop

        # Try to fetch README for better description
        $description = $repoInfo.description
        try {
            $readmeUrl = "https://raw.githubusercontent.com/$owner/$repo/main/README.md"
            # Fallback to master if main fails
            try {
                $readmeContent = Invoke-RestMethod -Uri $readmeUrl -ErrorAction Stop
            } catch {
                $readmeUrl = "https://raw.githubusercontent.com/$owner/$repo/master/README.md"
                $readmeContent = Invoke-RestMethod -Uri $readmeUrl -ErrorAction Stop
            }

            if ($readmeContent) {
                # Extract first paragraph or "About" section
                # Simple heuristic: look for the first non-header line that isn't a badge
                $lines = $readmeContent -split "`n"
                foreach ($line in $lines) {
                    $trimmed = $line.Trim()
                    if ($trimmed -and $trimmed -notmatch '^#' -and $trimmed -notmatch '!\[.*\]' -and $trimmed -notmatch '^<') {
                        if ($trimmed.Length -gt 20) {
                            # Clean Markdown syntax
                            $cleanDesc = $trimmed -replace '\[([^\]]+)\]\([^\)]+\)', '$1' # Links [text](url) -> text
                            $cleanDesc = $cleanDesc -replace '\*\*([^\*]+)\*\*', '$1'     # Bold **text** -> text
                            $cleanDesc = $cleanDesc -replace '\*([^\*]+)\*', '$1'         # Italic *text* -> text
                            $cleanDesc = $cleanDesc -replace '`([^`]+)`', '$1'            # Code `text` -> text

                            $description = $cleanDesc
                            "Extracted description from README: $description" | Write-Status -Level OK
                            break
                        }
                    }
                }
            }
        } catch {
            # Ignore README fetch errors
        }

        return @{
            Description = $description
            License     = $repoInfo.license.spdx_id
            LicenseUrl  = if ($repoInfo.license) { "https://raw.githubusercontent.com/$owner/$repo/main/LICENSE" } else { $null }
        }
    } elseif ($Platform -eq 'gitlab') {
        $apiUrl = "https://gitlab.com/api/v4/projects/$owner%2F$repo?license=true"
        'Fetching repository metadata...' | Write-Status -Level Info

        $repoInfo = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop

        return @{
            Description = $repoInfo.description
            License     = $repoInfo.license.key
            LicenseUrl  = $repoInfo.license.url
        }
    } elseif ($Platform -eq 'sourceforge') {
        $apiUrl = "https://sourceforge.net/rest/p/$Owner"
        'Fetching repository metadata...' | Write-Status -Level Info

        try {
            $repoInfo = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop

            return @{
                Description = $repoInfo.short_description
                License     = $null
                LicenseUrl  = $null
            }
        } catch {
            "Failed to fetch SourceForge metadata: $_" | Write-Status -Level Warn
            return @{
                Description = "SourceForge project $Owner"
                License     = $null
                LicenseUrl  = $null
            }
        }
    }
}

#endregion

#region Asset Functions

#region Analysis Functions

function Find-LicenseFile {
    <#
    .SYNOPSIS
    Attempts to find a license file in the extracted directory and identify the license type.
    #>
    [CmdletBinding()]
    param([string]$Directory)

    $licenseFiles = Get-ChildItem -Path $Directory -Recurse -Include 'LICENSE*', 'COPYING*', 'UNLICENSE*', 'gpl*.txt' -File | Select-Object -First 1

    if ($licenseFiles) {
        "Found license file: $($licenseFiles.Name)" | Write-Status -Level OK

        $content = Get-Content -Path $licenseFiles.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { return "Unknown (See $($licenseFiles.Name))" }

        # Normalize content for matching
        $content = $content -replace '\s+', ' '

        # License Patterns
        $patterns = @{
            'MIT'           = 'Permission is hereby granted.*free of charge.*to deal in the Software without restriction'
            'GPL-3.0-only'  = 'GNU General Public License.*version 3'
            'GPL-2.0-only'  = 'GNU General Public License.*version 2'
            'LGPL-3.0-only' = 'GNU Lesser General Public License.*version 3'
            'AGPL-3.0-only' = 'Affero General Public License'
            'Apache-2.0'    = 'Apache License.*Version 2\.0'
            'MPL-2.0'       = 'Mozilla Public License.*Version 2\.0'
            'BSD-3-Clause'  = 'Redistribution and use in source and binary forms.*with or without modification.*are permitted.*conditions.*Redistributions of source code must retain.*Redistributions in binary form must reproduce.*Neither the name'
            'BSD-2-Clause'  = 'Redistribution and use in source and binary forms.*with or without modification.*are permitted.*conditions.*Redistributions of source code must retain.*Redistributions in binary form must reproduce'
            'BSL-1.0'       = 'Boost Software License'
            'Unlicense'     = 'This is free and unencumbered software released into the public domain'
            'CC0-1.0'       = 'CC0 1\.0 Universal'
        }

        foreach ($license in $patterns.Keys) {
            if ($content -match $patterns[$license]) {
                "Identified license: $license" | Write-Status -Level OK
                return $license
            }
        }

        return "Unknown (See $($licenseFiles.Name))"
    }

    return $null
}

function Find-Dependencies {
    <#
    .SYNOPSIS
    Scans for dependencies based on file contents (e.g. VCRedist, .NET).
    #>
    [CmdletBinding()]
    param([string]$Directory)

    $depends = @()

    # Check for Visual C++ Redistributable dependencies
    # Heuristic: presence of msvcp*.dll, vcruntime*.dll often implies C++ runtime usage.
    $cppDlls = Get-ChildItem -Path $Directory -Recurse -Include 'msvcp*.dll', 'vcruntime*.dll', 'mfc*.dll' -File
    if ($cppDlls) {
        "Detected Visual C++ DLLs, adding 'vcredist' dependency" | Write-Status -Level Info
        $depends += 'vcredist'
    }

    # Check for .NET dependencies
    # Look for runtimeconfig.json which usually indicates .NET Core/5+
    $dotnetConfig = Get-ChildItem -Path $Directory -Recurse -Filter '*.runtimeconfig.json' -File
    if ($dotnetConfig) {
        "Detected .NET runtime configuration, adding 'dotnet-runtime' dependency" | Write-Status -Level Info
        $depends += 'dotnet-runtime'
    }

    # Check for OpenAL
    if (Get-ChildItem -Path $Directory -Recurse -Filter 'OpenAL32.dll' -File) {
        "Detected OpenAL DLL, adding 'openal' dependency" | Write-Status -Level Info
        $depends += 'openal'
    }

    # Check for Java dependencies
    # Heuristic: presence of .jar files
    $jarFiles = Get-ChildItem -Path $Directory -Recurse -Filter '*.jar' -File
    if ($jarFiles) {
        "Detected JAR files, adding 'java' dependency" | Write-Status -Level Info
        $depends += 'java'
    }

    # Check for DirectX
    # Heuristic: d3dcompiler_*.dll, d3dx9_*.dll, X3DAudio*_*.dll, XInput*_*.dll
    if (Get-ChildItem -Path $Directory -Recurse -Include 'd3dcompiler_*.dll', 'd3dx9_*.dll', 'X3DAudio*_*.dll', 'XInput*_*.dll' -File) {
        "Detected DirectX DLLs, adding 'directx' dependency" | Write-Status -Level Info
        $depends += 'directx'
    }

    return $depends | Select-Object -Unique
}

function Find-AuxiliaryBinaries {
    <#
    .SYNOPSIS
    Finds other useful executables in the package.
    #>
    [CmdletBinding()]
    param(
        [string]$Directory,
        [string]$MainExecutableName
    )

    $aux = @()
    $executables = Get-ChildItem -Path $Directory -Recurse -Filter '*.exe' -File

    foreach ($exe in $executables) {
        if ($exe.Name -eq $MainExecutableName) { continue }

        $name = $exe.Name.ToLower()
        # Skip installers/uninstallers
        if ($name -match 'unins|setup|install') { continue }
        # Skip common noise
        if ($name -match 'crash|report|update|config|debug') { continue }

        # Calculate relative path if needed, but for now just name if flat
        # If we have extract_dir, we assume flat structure inside it
        $aux += $exe.Name
    }

    return $aux
}

function Find-Notes {
    <#
    .SYNOPSIS
    Scans for items that should be added to the manifest notes.
    #>
    [CmdletBinding()]
    param([string]$Directory)

    $notes = @()

    # Check for registry files
    $regFiles = Get-ChildItem -Path $Directory -Recurse -Filter '*.reg' -File
    if ($regFiles) {
        $names = $regFiles.Name -join ', '
        "Found registry files: $names" | Write-Status -Level Info
        $notes += "Includes registry files: $names"
    }

    # Check for specific readme instructions (simple heuristic)
    $readmes = Get-ChildItem -Path $Directory -Recurse -Include 'README.txt', 'INSTALL.txt', 'INSTRUCTIONS.txt' -File
    foreach ($readme in $readmes) {
        $content = Get-Content -Path $readme.FullName -TotalCount 10 -ErrorAction SilentlyContinue
        if ($content -match 'BIOS') {
            $notes += "May require BIOS files (check $($readme.Name))"
        }
    }

    return $notes
}

function Test-InstallerType {
    <#
    .SYNOPSIS
    Checks if the executable is likely an installer (Inno Setup, NSIS, etc.).
    #>
    [CmdletBinding()]
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) { return $null }

    # Check if 7z can list it (Inno Setup, NSIS, MSI often can be opened by 7z)
    if (Get-Command '7z' -ErrorAction SilentlyContinue) {
        $output = & 7z l $FilePath 2>&1
        if ($LASTEXITCODE -eq 0) {
            $outputStr = $output | Out-String
            if ($outputStr -match 'Inno Setup') { return 'InnoSetup' }
            if ($outputStr -match 'NSIS') { return 'NSIS' }
            if ($outputStr -match 'WiX|MSI') { return 'MSI' }
            # If it lists files but isn't a standard archive extension, it's likely an installer
            if ($FilePath -notmatch '\.(zip|7z|tar|gz|rar)$') {
                return 'Archive/Installer'
            }
        }
    }

    # Fallback to naming conventions
    if ($FilePath -match 'setup|install') {
        return 'Generic Installer'
    }

    return $null
}

#endregion

function Get-AssetScore {
    <#
    .SYNOPSIS
    Calculates a score for an asset based on its name and extension.
    #>
    [CmdletBinding()]
    param([string]$Name)

    $score = 0
    $n = $Name.ToLower()

    # Extension scoring
    if ($n -match '\.zip$') { $score += 100 }
    elseif ($n -match '\.7z$') { $score += 90 }
    elseif ($n -match '\.tar\.gz$|\.tgz$') { $score += 80 }
    elseif ($n -match '\.jar$') { $score += 60 }
    elseif ($n -match '\.exe$') { $score += 0 }
    else { return -1 } # Not a preferred format

    # Keyword scoring
    if ($n -match 'sdl2') { $score += 50 }
    if ($n -match 'msys2|mingw') { $score += 40 }
    if ($n -match 'qt6') { $score += 30 }
    if ($n -match 'qt5') { $score += 20 }
    if ($n -match 'portable') { $score += 20 }

    # Penalties
    if ($n -match 'msvc') { $score -= 20 }
    if ($n -match 'debug|symbols|pdb') { $score -= 100 }
    if ($n -match 'installer|setup') { $score -= 50 }

    return $score
}

function Select-ArchitectureAssets {
    <#
    .SYNOPSIS
    Selects the best assets for each supported architecture.

    .DESCRIPTION
    Scores assets based on file extension and keywords for 64bit, 32bit, and arm64.
    #>
    [CmdletBinding()]
    param([object[]]$Assets)

    $archMap = @{}

    # Define architectures and their regex patterns
    $archPatterns = @{
        '64bit' = 'x64|x86_64|amd64|win64'
        '32bit' = 'x86|win32|ia32'
        'arm64' = 'arm64|aarch64'
    }

    foreach ($arch in $archPatterns.Keys) {
        $pattern = $archPatterns[$arch]
        $candidates = @($Assets | Where-Object {
                $_.name -match 'windows|win' -and $_.name -match $pattern
            })

        if ($candidates.Count -gt 0) {
            $best = $candidates | Select-Object @{N = 'Asset'; E = { $_ } }, @{N = 'Score'; E = { Get-AssetScore $_.name } } |
            Sort-Object Score -Descending | Select-Object -First 1

            if ($best.Score -ge 0) {
                $archMap[$arch] = $best.Asset
            }
        }
    }

    # Fallback: If no 64-bit found, but we have generic windows assets
    if (-not $archMap['64bit']) {
        $genericWindows = @($Assets | Where-Object {
                $_.name -match 'windows|win' -and
                $_.name -notmatch 'x86|win32|ia32|arm64|aarch64'
            })

        if ($genericWindows.Count -gt 0) {
            $best = $genericWindows | Select-Object @{N = 'Asset'; E = { $_ } }, @{N = 'Score'; E = { Get-AssetScore $_.name } } |
            Sort-Object Score -Descending | Select-Object -First 1

            if ($best.Score -ge 0) {
                $archMap['64bit'] = $best.Asset
                "Assumed generic Windows asset is 64-bit: $($best.Asset.name)" | Write-Status -Level Warn
            }
        }
    }

    return $archMap
}

function Get-AssetContent {
    [CmdletBinding()]
    param(
        [object]$Asset,
        [string]$OutputDirectory
    )

    $ProgressPreference = 'SilentlyContinue'

    $downloadUrl = if ($Asset.browser_download_url) { $Asset.browser_download_url } else { $Asset.url }
    $fileName = $Asset.name
    $outputPath = Join-Path $OutputDirectory $fileName

    $cacheDir = Join-Path $env:TEMP 'manifest-creator-cache'
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }

    $cachedFilePath = Join-Path $cacheDir $fileName

    if (Test-Path $cachedFilePath) {
        "Using cached file: $fileName" | Write-Status -Level Info
        Copy-Item -Path $cachedFilePath -Destination $outputPath -Force | Out-Null
        "Copied from cache to: $outputPath" | Write-Status -Level OK
        return $outputPath
    }

    "Downloading: $fileName" | Write-Status -Level Info
    Invoke-WebRequest -Uri $downloadUrl -OutFile $cachedFilePath -ErrorAction Stop -UseBasicParsing
    "Downloaded to cache: $cachedFilePath" | Write-Status -Level OK

    Copy-Item -Path $cachedFilePath -Destination $outputPath -Force | Out-Null
    "Copied to: $outputPath" | Write-Status -Level OK

    return $outputPath
}

function Expand-Asset {
    <#
    .SYNOPSIS
    Extracts an archive file to a specified directory.

    .DESCRIPTION
    Supports .zip natively. Requires 7z.exe in PATH for .7z, .tar.gz, .tgz, .rar.
    Supports Inno Setup (.exe) via innounp and MSI (.msi) via lessmsi if available.
    #>
    [CmdletBinding()]
    param(
        [string]$ArchivePath,
        [string]$ExtractDirectory
    )

    'Extracting archive...' | Write-Status -Level Info
    if (Test-Path $ExtractDirectory) {
        Remove-Item $ExtractDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $ExtractDirectory -Force | Out-Null

    $extension = [System.IO.Path]::GetExtension($ArchivePath).ToLower()

    if ($extension -eq '.zip') {
        Expand-Archive -Path $ArchivePath -DestinationPath $ExtractDirectory -ErrorAction Stop
    } elseif ($extension -match '\.(7z|tar\.gz|tgz|rar|xz|bz2)$') {
        if (Get-Command '7z' -ErrorAction SilentlyContinue) {
            $null = & 7z x $ArchivePath "-o$ExtractDirectory" -y
            if ($LASTEXITCODE -ne 0) {
                throw "7-Zip extraction failed with exit code $LASTEXITCODE"
            }
        } else {
            throw "7-Zip (7z) is required to extract this archive type ($extension). Please install 7zip."
        }
    } elseif ($extension -eq '.exe') {
        # Try Inno Setup Unpacker (innounp)
        if (Get-Command 'innounp' -ErrorAction SilentlyContinue) {
            "Attempting Inno Setup extraction with innounp..." | Write-Status -Level Info
            $null = & innounp -x -d"$ExtractDirectory" "$ArchivePath"
            if ($LASTEXITCODE -eq 0) {
                "Inno Setup extraction successful." | Write-Status -Level OK
                return $ExtractDirectory
            }
        }

        # Try 7-Zip as fallback for self-extracting archives
        if (Get-Command '7z' -ErrorAction SilentlyContinue) {
            "Attempting extraction with 7-Zip..." | Write-Status -Level Info
            $null = & 7z x $ArchivePath "-o$ExtractDirectory" -y
            if ($LASTEXITCODE -eq 0) {
                return $ExtractDirectory
            }
        }

        throw "Could not extract .exe file. Install 'innounp' for Inno Setup installers or check if it's a valid archive."
    } elseif ($extension -eq '.msi') {
        if (Get-Command 'lessmsi' -ErrorAction SilentlyContinue) {
            "Attempting MSI extraction with lessmsi..." | Write-Status -Level Info
            $null = & lessmsi x "$ArchivePath" "$ExtractDirectory"
            if ($LASTEXITCODE -eq 0) {
                return $ExtractDirectory
            }
        }

        # Try 7-Zip as fallback
        if (Get-Command '7z' -ErrorAction SilentlyContinue) {
            "Attempting extraction with 7-Zip..." | Write-Status -Level Info
            $null = & 7z x $ArchivePath "-o$ExtractDirectory" -y
            if ($LASTEXITCODE -eq 0) {
                return $ExtractDirectory
            }
        }

        throw "Could not extract .msi file. Install 'lessmsi' or '7zip'."
    } else {
        throw "Unsupported archive format: $extension"
    }

    "Archive extracted to: $ExtractDirectory" | Write-Status -Level OK

    return $ExtractDirectory
}

#endregion

#region Executable Functions

function Find-Executable {
    [CmdletBinding()]
    param(
        [string]$SearchDirectory,
        [string]$ProjectName,
        [switch]$NonInteractive
    )

    $executables = @(Get-ChildItem -Path $SearchDirectory -Filter '*.exe' -Recurse |
        Sort-Object Length -Descending |
        Select-Object -First 20)

    # If no executables found, check for JAR files
    if ($executables.Count -eq 0) {
        $jars = @(Get-ChildItem -Path $SearchDirectory -Filter '*.jar' -Recurse | Select-Object -First 20)
        if ($jars.Count -gt 0) {
            "No .exe found, but detected .jar files. Using JAR as executable." | Write-Status -Level Info
            $executables = $jars
        } else {
            throw 'No executables (.exe) or JAR files (.jar) found in extracted archive'
        }
    }

    if ($executables.Count -eq 1) {
        "Found executable: $($executables[0].Name)" | Write-Status -Level OK
        return $executables[0]
    }

    $projectNameLower = $ProjectName.ToLower()
    $scoredExecutables = @()

    foreach ($exe in $executables) {
        $score = 0
        $name = $exe.BaseName.ToLower()

        # Name matching
        if ($name -eq $projectNameLower) { $score += 100 }
        elseif ($name.StartsWith($projectNameLower)) { $score += 50 }
        elseif ($name.Contains($projectNameLower)) { $score += 30 }

        # Positive keywords
        if ($name -match 'launcher') { $score += 20 }
        if ($name -match 'gui') { $score += 20 }
        if ($name -match 'qt|wx|gtk') { $score += 10 }
        if ($name -match 'emu') { $score += 10 }

        # Negative keywords
        if ($name -match 'console|cli|server|cmd|headless') { $score -= 20 }
        if ($name -match 'debug|test|sample|example|demo') { $score -= 30 }
        if ($name -match 'unins') { $score -= 100 }
        if ($name -match 'setup|install|update|config|crash') { $score -= 50 }
        if ($name -match 'dx|gl|vk') { $score -= 10 } # Graphics backend binaries often separate

        $scoredExecutables += [PSCustomObject]@{
            Executable = $exe
            Score      = $score
            Name       = $exe.Name
        }
    }

    $sortedExecutables = $scoredExecutables | Sort-Object Score -Descending

    # If the top score is significantly higher than the rest, pick it automatically
    if ($sortedExecutables.Count -gt 1) {
        $topScore = $sortedExecutables[0].Score
        $secondScore = $sortedExecutables[1].Score

        if (($topScore -ge 50) -and ($topScore - $secondScore -ge 20)) {
            "Found likely main executable: $($sortedExecutables[0].Name)" | Write-Status -Level OK
            return $sortedExecutables[0].Executable
        }
    }

    # Multiple candidates with similar scores, need user selection
    '' | Write-Status
    'Multiple executables found. Please select one:' | Write-Status -Level Warn

    $displayCount = [math]::Min($sortedExecutables.Count, 10)
    for ($i = 0; $i -lt $displayCount; $i++) {
        $item = $sortedExecutables[$i]
        $isDefault = if ($i -eq 0) { ' [DEFAULT - press Enter]' } else { '' }
        "  [$($i + 1)] $($item.Name) (Score: $($item.Score))$isDefault" | Write-Status -Level Info
    }

    # Check for non-interactive mode (for testing/automation)
    $isNonInteractive = Get-NonInteractivePreference -Override:$NonInteractive

    if (-not $isNonInteractive) {
        do {
            try {
                $choice = Read-Host "Select executable (1-$displayCount, or press Enter for default)"
                if ([string]::IsNullOrWhiteSpace($choice)) {
                    $selectedIndex = 0
                    break
                }
                $selectedIndex = [int]$choice - 1
            } catch {
                $selectedIndex = -1
            }

            if ($selectedIndex -lt 0 -or $selectedIndex -ge $displayCount) {
                "Invalid selection. Please enter a number between 1 and $displayCount." | Write-Status -Level Warn
            }
        } until ($selectedIndex -ge 0 -and $selectedIndex -lt $displayCount)
    } else {
        # Non-interactive mode: use default (first item)
        "Using default selection in non-interactive mode: $($sortedExecutables[0].Name)" | Write-Status -Level OK
        $selectedIndex = 0
    }
    '' | Write-Status

    "Selected: $($sortedExecutables[$selectedIndex].Name)" | Write-Status -Level OK
    return $sortedExecutables[$selectedIndex].Executable
}

#endregion

#region Platform Detection

function Find-EmulatorPlatform {
    [CmdletBinding()]
    param(
        [string]$RepositoryName,
        [string]$Description
    )

    $platformPatterns = @{
        'Nintendo 64'           = 'gopher64|mupen64|n64|project64|rmg|simple64'
        'Nintendo GameCube/Wii' = 'dolphin|ishiruka'
        'Nintendo Wii U'        = 'cemu|wiiu|decaf'
        'Nintendo Switch'       = 'yuzu|ryujinx|suyu|sudachi|torzu|citron'
        'Nintendo 3DS'          = 'citra|lime3ds|pablo|mandarine|azahar'
        'Nintendo DS'           = 'melonds|desmume|no\$gba'
        'Super Nintendo'        = 'fceux|snes9x|bsnes|mesen|higan|ares'
        'Nintendo'              = 'nestopia|fceux|mesen|puNES'
        'PlayStation 1'         = 'duckstation|mednafen|pcsx|epsxe'
        'PlayStation 2'         = 'pcsx2|play!'
        'PlayStation 3'         = 'rpcs3'
        'PlayStation 4'         = 'shadps4|fpse'
        'PlayStation Portable'  = 'ppsspp'
        'PlayStation Vita'      = 'vita3k'
        'Sega Dreamcast'        = 'flycast|redream|demul|lxdream'
        'Sega Genesis'          = 'genesis|mega|kega|fusion'
        'Sega Saturn'           = 'yabause|mednafen|kronos|ssf'
        'Microsoft Xbox'        = 'xemu|cxbx'
        'Microsoft Xbox 360'    = 'xenia'
        'Game Boy/Color'        = 'mgba|visualboyadvance|sameboy|bgb|gambatte'
        'Arcade'                = 'mame|fbneo|finalburn'
        'Multi-System'          = 'retroarch|advancemame|bizhawk|ares|mednafen'
        'ScummVM'               = 'scummvm'
    }

    $searchText = "$RepositoryName $Description".ToLower()

    foreach ($platform in $platformPatterns.Keys) {
        $pattern = $platformPatterns[$platform]
        if ($searchText -match $pattern) {
            return $platform
        }
    }

    return $null
}

#endregion

#region Validation Functions (Manifest)

function Invoke-ManifestValidation {
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        [string]$BucketDirectory,
        [string]$AppName
    )

    $scriptsToRun = @(
        @{
            Name   = 'checkver'
            Script = 'checkver.ps1'
            Args   = @{ Dir = $BucketDirectory; App = $AppName }
        },
        @{
            Name   = 'check-autoupdate'
            Script = 'check-autoupdate.ps1'
            Args   = @{ ManifestPath = $ManifestPath }
        },
        @{
            Name   = 'check-manifest-install'
            Script = 'check-manifest-install.ps1'
            Args   = @{ ManifestPath = $ManifestPath }
        }
    )

    $allPassed = $true
    $results = @()

    foreach ($test in $scriptsToRun) {
        $scriptPath = Join-Path $PSScriptRoot $test.Script
        if (-not (Test-Path $scriptPath)) {
            "[WARN] $($test.Name) not found, skipping..." | Write-Status -Level Warn
            $results += @{ Name = $test.Name; Status = 'SKIP'; Message = 'Script not found' }
            continue
        }

        "Running $($test.Name)..." | Write-Status -Level Info
        try {
            $argArray = $test.Args
            $output = & $scriptPath @argArray 2>&1
            if ($LASTEXITCODE -eq 0) {
                "[OK] $($test.Name) passed" | Write-Status -Level OK
                $results += @{ Name = $test.Name; Status = 'PASS'; Message = '' }
            } else {
                "[FAIL] $($test.Name) failed" | Write-Status -Level Error
                $results += @{ Name = $test.Name; Status = 'FAIL'; Message = ($output | Out-String) }
                $allPassed = $false
            }
        } catch {
            "[FAIL] $($test.Name) threw error: $_" | Write-Status -Level Error
            $results += @{ Name = $test.Name; Status = 'FAIL'; Message = $_.Exception.Message }
            $allPassed = $false
        }
    }

    return @{
        AllPassed = $allPassed
        Results   = $results
    }
}

#endregion

function Get-ReleaseChecksum {
    [CmdletBinding()]
    param(
        [object[]]$Assets,
        [string]$TargetAssetName
    )

    $checksumPatterns = @('*.sha256', '*.sha256sum', '*.sha256.txt', '*.checksum', '*.hashes', '*.DIGEST')
    $checksumAssets = @()

    foreach ($pattern in $checksumPatterns) {
        $checksumAssets += @($Assets | Where-Object { $_.name -like $pattern })
    }

    if ($checksumAssets.Count -gt 0) {
        foreach ($checksumAsset in $checksumAssets) {
            try {
                $downloadUrl = if ($checksumAsset.browser_download_url) { $checksumAsset.browser_download_url } else { $checksumAsset.url }

                # Download content directly without temp file
                $content = Invoke-RestMethod -Uri $downloadUrl -ErrorAction Stop

                if ($content -isnot [string]) {
                    $content = $content | Out-String
                }

                $lines = $content -split "`n" | Where-Object { $_ -match '\S' }

                foreach ($line in $lines) {
                    if ($line -match '^([a-f0-9]{64})\s+(.+?)$' -or $line -match '^(.+?)\s+([a-f0-9]{64})$') {
                        $hash = if ($matches[1] -match '^[a-f0-9]{64}$') { $matches[1] } else { $matches[2] }
                        $filename = if ($matches[1] -match '^[a-f0-9]{64}$') { $matches[2] } else { $matches[1] }

                        # Clean up filename (remove * and whitespace)
                        $filename = $filename.Trim().Trim('*')

                        if ($filename -like "*$($TargetAssetName)*" -or $TargetAssetName -like "*$filename*") {
                            "Found SHA256 from release: $hash" | Write-Status -Level OK
                            return $hash
                        }
                    }
                }
            } catch {
                "Failed to parse checksum file: $_" | Write-Status -Level Warn
            }
        }
    }

    return $null
}

function ConvertTo-FileHash {
    [CmdletBinding()]
    param([string]$FilePath)

    $hash = Get-FileHash -Path $FilePath -Algorithm SHA256
    return $hash.Hash
}

#endregion

#region Portable Mode

function Get-DirectorySnapshot {
    param([string]$Path)
    $snapshot = @{}
    Get-ChildItem -Path $Path -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { $snapshot[$_.FullName] = $_.LastWriteTime }
    return $snapshot
}

function Test-PortableMode {
    [CmdletBinding()]
    param(
        [string]$ExecutablePath,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 30,
        [bool]$IsNonInteractive = $false
    )

    'Creating portable structure...' | Write-Status -Level Info

    $userFolder = Join-Path $WorkingDirectory 'user'
    $portableFolder = Join-Path $WorkingDirectory 'portable'

    New-Item -ItemType Directory -Path $userFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $portableFolder -Force | Out-Null

    'Monitoring for files/folders created during execution...' | Write-Status -Level Info

    if (-not $IsNonInteractive) {
        @'

========================================
IMPORTANT - Persist Configuration
========================================
The application will now launch. Before closing it:
  1. Change some settings in the application
  2. Create or modify files/preferences

WARNING: If you don't change any settings, the persist
folder will be empty, and your data will NOT be saved!

After making changes, close the application normally.
========================================

'@ | Write-Status -Level Warn
        "Timeout: ${TimeoutSeconds}s (close the application to continue)" | Write-Status -Level Info
    } else {
        "Timeout: ${TimeoutSeconds}s (auto-closing)" | Write-Status -Level Info
    }

    $initialSnapshot = Get-DirectorySnapshot -Path $WorkingDirectory

    try {
        $process = Start-Process -FilePath $ExecutablePath -WorkingDirectory $WorkingDirectory -PassThru -ErrorAction Stop
        $startTime = Get-Date

        while (-not $process.HasExited) {
            if (((Get-Date) - $startTime).TotalSeconds -gt $TimeoutSeconds) {
                if ($IsNonInteractive) {
                    '[INFO] Timeout reached, auto-closing application...' | Write-Status -Level Info
                    $process | Stop-Process -Force -ErrorAction SilentlyContinue
                } else {
                    '[INFO] Timeout reached. Please close the application manually or press ENTER if already closed...' | Write-Status -Level Info
                    # Give user a chance to react if they are slow
                    if ([Console]::KeyAvailable) {
                        $null = [Console]::ReadKey($true)
                    }
                }
                break
            }
            Start-Sleep -Milliseconds 500
        }

        # Ensure process is really gone
        if (-not $process.HasExited) {
            $process | Stop-Process -Force -ErrorAction SilentlyContinue
        }

    } catch {
        "Could not start executable for monitoring: $_" | Write-Status -Level Warn
        return @{
            Items               = @()
            HasPersist          = $false
            UsesStandardFolders = $false
        }
    }

    # Wait a moment for file system to settle
    Start-Sleep -Seconds 1

    $createdItems = @()
    Get-ChildItem -Path $WorkingDirectory -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object {
        if (-not $initialSnapshot.ContainsKey($_.FullName)) {
            $createdItems += $_.FullName
        }
    }

    $persistItems = @()
    $usesStandardFolders = $false

    # Check standard folders
    if ((Test-Path $userFolder) -and (Get-ChildItem $userFolder -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        $persistItems += 'user'
        $usesStandardFolders = $true
        "'user' folder has content, will persist" | Write-Status -Level OK
    }

    if ((Test-Path $portableFolder) -and (Get-ChildItem $portableFolder -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        $persistItems += 'portable'
        $usesStandardFolders = $true
        "'portable' folder has content, will persist" | Write-Status -Level OK
    }

    # Check for other created items
    if ($createdItems.Count -gt 0) {
        'Detected other created items (potential persist candidates):' | Write-Status -Level Info
        $otherCandidates = @()

        foreach ($item in $createdItems) {
            $relativePath = $item -replace [regex]::Escape($WorkingDirectory), '' -replace '^\\', ''
            # Filter out standard folders and temp files
            if ($relativePath -and
                $relativePath -notmatch '^(portable\.txt|user|portable)(\\|$)' -and
                $relativePath -notmatch '\.log$|\.tmp$|\.cache$') {

                # Get top-level folder/file
                $topLevel = ($relativePath -split '\\')[0]
                if ($topLevel -notin $otherCandidates) {
                    $otherCandidates += $topLevel
                }
            }
        }

        foreach ($candidate in $otherCandidates) {
            "  - $candidate" | Write-Status -Level Info
            # In non-interactive mode, we might want to be conservative and NOT add these automatically
            # unless we are sure. For now, we just list them.
            # If we wanted to be aggressive: $persistItems += $candidate
        }
    }

    return @{
        Items               = $persistItems
        HasPersist          = $persistItems.Count -gt 0
        UsesStandardFolders = $usesStandardFolders
    }
}

#endregion

#region Manifest Functions

function Get-ManifestVersion {
    [CmdletBinding()]
    param(
        [hashtable]$RepositoryInfo,
        [object]$Asset,
        [string]$BuildType
    )

    $versionToUse = $RepositoryInfo.Version

    if ($BuildType -in @('nightly', 'dev')) {
        # Try to extract commit hash from asset filename
        $assetName = $Asset.name
        if ($assetName -match '-([a-f0-9]+)[-\.]') {
            $versionToUse = $matches[1]
            "Using commit hash from filename: $versionToUse" | Write-Status -Level OK
        } elseif ($RepositoryInfo.CommitHash) {
            # Fallback to commit hash from API
            $commitHash = $RepositoryInfo.CommitHash
            if ($commitHash.Length -gt 7) {
                $commitHash = $commitHash.Substring(0, 7)
            }
            $versionToUse = $commitHash
            "Using commit hash from API: $versionToUse" | Write-Status -Level OK
        } else {
            # Final fallback to repository version
            $versionToUse = $RepositoryInfo.Version
            "Using version from repository: $versionToUse" | Write-Status -Level Warn
        }
    }

    return $versionToUse
}

function Get-ManifestCheckver {
    [CmdletBinding()]
    param(
        [hashtable]$RepositoryInfo,
        [string]$BuildType
    )

    if ($RepositoryInfo.Platform -eq 'github') {
        if ($BuildType -in @('nightly', 'dev')) {
            # For nightly/dev builds, get commit hash from the branch
            $branchName = 'main'
            if ($RepositoryInfo.TargetRef -and ($RepositoryInfo.TargetRef -notmatch '^[0-9a-f]{7,}$')) {
                $branchName = $RepositoryInfo.TargetRef
            } elseif ($RepositoryInfo.CommitHash -and ($RepositoryInfo.CommitHash -notmatch '^[0-9a-f]{7,}$')) {
                $branchName = $RepositoryInfo.CommitHash
            }
            return @{
                'url' = "https://api.github.com/repos/$($RepositoryInfo.Owner)/$($RepositoryInfo.Repo)/branches/$branchName"
                'jp'  = "$.commit.sha"
                're'  = '^(.{7})'
            }
        } else {
            $checkver = @{ 'github' = $RepositoryInfo.RepoUrl }

            # Analyze tag name for regex generation
            # If tag is like "release-1.2.3" or "app_v1.2.3", generate a regex
            $tagName = $RepositoryInfo.TagName
            if ($tagName -match '^(?<prefix>[a-zA-Z-_]+)(?<version>\d+\.\d+(\.\d+)?)$') {
                $prefix = [regex]::Escape($matches['prefix'])
                $checkver['re'] = "$prefix([\d\.]+)"
                "Generated checkver regex for tag '$tagName': $($checkver['re'])" | Write-Status -Level OK
            }

            return $checkver
        }
    } elseif ($RepositoryInfo.Platform -eq 'gitlab') {
        if ($BuildType -in @('nightly', 'dev')) {
            $projectPath = "$($RepositoryInfo.Owner)%2F$($RepositoryInfo.Repo)"
            return @{
                'url' = "https://gitlab.com/api/v4/projects/$projectPath/repository/commits"
                'jp'  = "$[0].short_id"
            }
        } else {
            return @{ 'gitlab' = $RepositoryInfo.RepoUrl }
        }
    } elseif ($RepositoryInfo.Platform -eq 'sourceforge') {
        return @{
            'sourceforge' = $RepositoryInfo.Repo
            're'          = '(?<version>[\d\.]+)'
        }
    }
}

function Get-ManifestAutoupdate {
    <#
    .SYNOPSIS
    Generates the autoupdate configuration.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$RepositoryInfo,
        [hashtable]$ArchitectureAssets,
        [string]$BuildType,
        [string]$ExtractDir
    )

    $autoupdate = [ordered]@{
        'architecture' = [ordered]@{}
    }

    # Handle extract_dir templating
    if ($ExtractDir -and ($RepositoryInfo.Version -ne 'nightly' -and $RepositoryInfo.Version -ne 'dev')) {
        $version = $RepositoryInfo.Version
        if ($version.StartsWith('v')) { $version = $version.Substring(1) }

        if ($ExtractDir.Contains($version)) {
            $autoupdate['extract_dir'] = $ExtractDir.Replace($version, '$version')
        }
    }

    foreach ($arch in $ArchitectureAssets.Keys) {
        $asset = $ArchitectureAssets[$arch]
        $url = $asset.browser_download_url

        # Replace version with $version placeholder
        if ($RepositoryInfo.Version -ne 'nightly' -and $RepositoryInfo.Version -ne 'dev') {
            $version = $RepositoryInfo.Version
            if ($version.StartsWith('v')) { $version = $version.Substring(1) }
            $url = $url.Replace($version, '$version')
        }

        # For nightly/dev, we don't use $version in URL usually, but if we do, it's handled by checkver
        # However, for autoupdate, we often want to capture the structure

        $autoupdateArch = [ordered]@{
            'url' = $url
        }

        # Add hash extraction if needed (usually handled by checkver for stable)
        # For nightly, we don't add hash to autoupdate usually as it's skipped

        $autoupdate['architecture'][$arch] = $autoupdateArch
    }

    return $autoupdate
}

function Get-ManifestPreInstall {
    [CmdletBinding()]
    param(
        [array]$PersistItems,
        [bool]$UsesStandardFolders,
        [string]$RepoName
    )

    $persistFolders = @()
    foreach ($item in $PersistItems) {
        $topLevelFolder = ($item -split '\\')[0]
        if ($topLevelFolder -and $persistFolders -notcontains $topLevelFolder) {
            $persistFolders += $topLevelFolder
        }
    }

    $portableTxtCode = ''
    if (-not $UsesStandardFolders) {
        $portableTxtCode = "# Create portable marker file (used as fallback indicator for portable mode)`n" + 'Add-Content -Path "$dir\portable.txt" -Value '''' -Encoding UTF8' + "`n"
    }

    $folderCreationCode = ''
    foreach ($folder in $persistFolders) {
        if ($folder -in @('user', 'portable')) {
            $folderCreationCode += @"

# Ensure $folder folder exists
if (-not (Test-Path "`$dir\$folder")) {
    New-Item -ItemType Directory -Path "`$dir\$folder" -Force | Out-Null
}
"@
        }
    }

    $repoNameLower = $RepoName.ToLower()
    return $portableTxtCode + $folderCreationCode + @"

`$appDataPath = `$env:APPDATA
`$documentsPath = [Environment]::GetFolderPath('MyDocuments')

# Migrate application data from common locations
`$appDataPath, `$documentsPath | ForEach-Object {
    `$path = if (`$_ -eq `$appDataPath) { "`$appDataPath\$repoNameLower" } else { "`$documentsPath\$repoNameLower" }
    if (Test-Path `$path) {
        `$items = Get-ChildItem -Path `$path -Force
        if (`$items) {
            Write-Host "Migrating data from `$path"
            `$items | Copy-Item -Destination "`$dir\portable_data" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
"@
}

function New-ScoopManifest {
    <#
    .SYNOPSIS
    Constructs the Scoop manifest object.

    .DESCRIPTION
    Assembles all manifest components (version, description, architecture, etc.) into an ordered dictionary.
    #>
    [CmdletBinding()]
    param(
        [hashtable]$RepositoryInfo,
        [hashtable]$ArchitectureAssets,
        [string]$ExecutableName,
        [array]$PersistItems,
        [hashtable]$Metadata,
        [string]$Platform,
        [string]$BuildType = 'stable',
        [bool]$UsesStandardFolders = $false,
        [string]$LicenseFile,
        [array]$Dependencies,
        [string]$ExtractDir,
        [string[]]$Notes,
        [string[]]$AuxiliaryBinaries
    )

    $assetToUse = if ($ArchitectureAssets['64bit']) { $ArchitectureAssets['64bit'] } else { $ArchitectureAssets['32bit'] }
    $versionToUse = Get-ManifestVersion -RepositoryInfo $RepositoryInfo -Asset $assetToUse -BuildType $BuildType

    $manifest = [ordered]@{
        'version'  = $versionToUse
        'homepage' = $RepositoryInfo.RepoUrl
    }

    if ($Platform) {
        $manifest['description'] = "$Platform Emulator"
    } elseif ($Metadata.Description) {
        $manifest['description'] = $Metadata.Description
    } else {
        $manifest['description'] = $RepositoryInfo.Repo
    }

    $manifest['license'] = Get-ManifestLicense -Metadata $Metadata -LicenseFile $LicenseFile

    if ($Notes) {
        if ($Notes.Count -eq 1) {
            $manifest['notes'] = $Notes[0]
        } else {
            $manifest['notes'] = $Notes
        }
    }

    if ($Dependencies) {
        $manifest['depends'] = $Dependencies
    }

    # Generate suggestions based on dependencies
    if ($Dependencies) {
        $suggestions = [ordered]@{}
        if ($Dependencies -contains 'java') {
            $suggestions['java'] = @('java/openjdk', 'java/oraclejdk')
        }
        if ($Dependencies -contains 'vcredist') {
            $suggestions['vcredist'] = @('extras/vcredist2022')
        }
        if ($Dependencies -contains 'dotnet-runtime') {
            $suggestions['dotnet-runtime'] = @('extras/dotnet-runtime')
        }

        if ($suggestions.Count -gt 0) {
            $manifest['suggest'] = $suggestions
        }
    }

    if ($ExtractDir) {
        $manifest['extract_dir'] = $ExtractDir
    }

    $manifest['architecture'] = Get-ManifestArchitecture -ArchitectureAssets $ArchitectureAssets

    $binList = @($ExecutableName)
    if ($AuxiliaryBinaries) {
        $binList += $AuxiliaryBinaries
    }

    if ($binList.Count -eq 1) {
        $manifest['bin'] = $binList[0]
    } else {
        $manifest['bin'] = $binList
    }

    if ($Platform) {
        $platformAbbrev = @{
            'Nintendo 64'           = 'n64'
            'Nintendo GameCube/Wii' = 'gc'
            'Nintendo Wii U'        = 'wiiu'
            'Nintendo Switch'       = 'switch'
            'Nintendo 3DS'          = '3ds'
            'Nintendo DS'           = 'ds'
            'Super Nintendo'        = 'snes'
            'Nintendo'              = 'nes'
            'PlayStation 1'         = 'ps1'
            'PlayStation 2'         = 'ps2'
            'PlayStation 3'         = 'ps3'
            'PlayStation Portable'  = 'psp'
            'Sega Genesis'          = 'genesis'
            'Sega Dreamcast'        = 'dreamcast'
            'Game Boy'              = 'gb'
            'Arcade'                = 'arcade'
            'Multi-System'          = 'multi'
        }

        $abbrev = $platformAbbrev[$Platform]
        if (-not $abbrev) {
            $abbrev = ($Platform -split '\s' | Select-Object -First 1).ToLower()
        }

        $exeName = $ExecutableName -replace '\.exe$', ''
        $shortcutLabel = "$Platform [$abbrev][$exeName]"
    } else {
        $appName = $ExecutableName -replace '\.exe$', ''
        $shortcutLabel = $appName
    }

    $manifest['shortcuts'] = , @($ExecutableName, $shortcutLabel)

    $persistArray = @()
    if ($PersistItems.Count -gt 0) {
        $validItems = $PersistItems | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
        if ($validItems.Count -gt 0) {
            $persistArray = $validItems
        }
    }

    if ($persistArray.Count -gt 0) {
        # Always use array format for persist to allow easier editing later
        $manifest['persist'] = @($persistArray)
    }

    $manifest['pre_install'] = Get-ManifestPreInstall -PersistItems $PersistItems -UsesStandardFolders $UsesStandardFolders -RepoName $RepositoryInfo.Repo

    $manifest['checkver'] = Get-ManifestCheckver -RepositoryInfo $RepositoryInfo -BuildType $BuildType

    $manifest['autoupdate'] = Get-ManifestAutoupdate -RepositoryInfo $RepositoryInfo -ArchitectureAssets $ArchitectureAssets -BuildType $BuildType -ExtractDir $ExtractDir

    $orderedKeys = @(
        'version', 'description', 'homepage', 'license', 'notes', 'depends', 'suggest',
        'identifier', 'url', 'hash', 'architecture', 'extract_dir', 'extract_to',
        'pre_install', 'installer', 'post_install', 'env_add_path', 'env_set',
        'bin', 'shortcuts', 'persist', 'uninstaller', 'checkver', 'autoupdate',
        '64bit', '32bit', 'arm64'
    )

    $orderedManifest = [ordered]@{}
    foreach ($key in $orderedKeys) {
        if ($manifest.Contains($key)) {
            $orderedManifest[$key] = $manifest[$key]
        }
    }

    foreach ($key in $manifest.Keys) {
        if (-not $orderedManifest.Contains($key)) {
            $orderedManifest[$key] = $manifest[$key]
        }
    }

    return $orderedManifest
}

function ConvertTo-JsonValue {
    [CmdletBinding()]
    param(
        [object]$Value,
        [int]$Indent = 0
    )

    $indentStr = ' ' * $Indent

    if ($null -eq $Value) {
        return 'null'
    }

    if ($Value -is [string]) {
        $escaped = $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
        return "`"$escaped`""
    }

    if ($Value -is [bool]) {
        return if ($Value) { 'true' } else { 'false' }
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
        return $Value.ToString()
    }

    if ($Value -is [array]) {
        if ($Value.Count -eq 0) {
            return '[]'
        }

        if ($Value[0] -is [array]) {
            $subItems = $Value | ForEach-Object {
                $item = $_
                $subIndent = ' ' * ($Indent + 4)
                if ($item -is [array]) {
                    $subElements = $item | ForEach-Object { ConvertTo-JsonValue -Value $_ -Indent ($Indent + 8) }
                    "$subIndent[`n$subIndent  $($subElements -join ",`n$subIndent  ")`n$subIndent]"
                } else {
                    "$subIndent$(ConvertTo-JsonValue -Value $item -Indent ($Indent + 4))"
                }
            }
            return "[`n$($subItems -join ",`n")`n$indentStr]"
        }

        $items = $Value | ForEach-Object { "$indentStr  $(ConvertTo-JsonValue -Value $_ -Indent ($Indent + 2))" }
        return "[`n$($items -join ",`n")`n$indentStr]"
    }

    if ($Value -is [hashtable] -or $Value -is [System.Collections.Specialized.OrderedDictionary]) {
        if ($Value.Count -eq 0) {
            return '{}'
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

function Export-Manifest {
    [CmdletBinding()]
    param(
        [hashtable]$Manifest,
        [string]$RepositoryName,
        [string]$OutputDirectory
    )



    # Strip CI, Dev, Nightly suffixes (case-insensitive) and convert to lowercase
    $cleanedName = $RepositoryName -replace '(?i)([-_]?(ci|dev|nightly))$', ''
    $cleanedName = $cleanedName.ToLower()

    $jsonPath = Join-Path $OutputDirectory "$cleanedName.json"

    $lines = @('{')
    $keyOrder = @(
        'version', 'description', 'homepage', 'license', 'notes', 'depends', 'suggest',
        'identifier', 'url', 'hash', 'architecture', 'extract_dir', 'extract_to',
        'pre_install', 'installer', 'post_install', 'env_add_path', 'env_set',
        'bin', 'shortcuts', 'persist', 'uninstaller', 'checkver', 'autoupdate',
        '64bit', '32bit', 'arm64'
    )

    $processedKeys = @()
    $allKeys = $Manifest.Keys

    foreach ($key in $keyOrder) {
        if ($allKeys -contains $key) {
            $processedKeys += $key
            $value = $Manifest[$key]
            $jsonValue = ConvertTo-JsonValue -Value $value -Indent 2
            $lines += "  `"$key`": $jsonValue,"
        }
    }

    foreach ($key in $allKeys) {
        if ($processedKeys -notcontains $key) {
            $value = $Manifest[$key]
            $jsonValue = ConvertTo-JsonValue -Value $value -Indent 2
            $lines += "  `"$key`": $jsonValue,"
        }
    }

    $lines[-1] = $lines[-1] -replace ',$', ''
    $lines += '}'

    $json = $lines -join "`n"

    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($jsonPath, $json + "`n", $utf8NoBom)

    'Manifest saved to: ' + $jsonPath | Write-Status -Level OK
    'Run ''npx prettier --write ' + "$cleanedName.json'" + ''' to format the JSON' | Write-Status -Level Info

    return $jsonPath
}

function New-PullRequest {
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        [string]$AppName,
        [string]$Version,
        [string]$RepoUrl
    )

    if (-not (Get-Command 'gh' -ErrorAction SilentlyContinue)) {
        "GitHub CLI (gh) not found. Skipping PR creation." | Write-Status -Level Warn
        return
    }

    if (-not (gh auth status 2>&1)) {
        "GitHub CLI not authenticated. Skipping PR creation." | Write-Status -Level Warn
        return
    }

    $branchName = "add-$AppName-$Version"
    "Creating branch $branchName..." | Write-Status -Level Info

    # Create branch
    git checkout -b $branchName 2>$null
    if ($LASTEXITCODE -ne 0) {
        "Failed to create branch. You might have uncommitted changes." | Write-Status -Level Warn
        return
    }

    # Add file
    git add $ManifestPath
    git commit -m "feat($AppName): add manifest for $AppName v$Version"

    # Push and create PR
    "Pushing branch and creating PR..." | Write-Status -Level Info
    git push -u origin $branchName

    $body = "Added manifest for [$AppName]($RepoUrl) version $Version.`n`nAuto-generated by create-manifest.ps1."
    gh pr create --title "feat($AppName): add manifest for $AppName" --body $body --web
}


#endregion

#region Main Script

$infoMessage = @'
========================================
Scoop Manifest Creator
========================================

Automatically generates Scoop manifests for GitHub/GitLab releases.
Auto-detects and configures stable, nightly, and dev builds.

Usage:

  From repository URL (GitHub, GitLab, SourceForge):
    .\create-manifest.ps1 -RepoUrl 'https://github.com/owner/repo'

  From GitHub tag/release:
    .\create-manifest.ps1 -RepoUrl 'https://github.com/owner/repo/releases/tag/nightly'

  From GitHub issue (auto-updates issue):
    .\create-manifest.ps1 -IssueNumber 123 -GitHubToken 'ghp_xxx'

Parameters:
  -RepoUrl      Repository URL (GitHub, GitLab, or SourceForge)
  -IssueNumber  GitHub issue number (extracts repo from issue body)
  -GitHubToken  GitHub personal access token (required for -IssueNumber)

Detected Build Types:
  Stable       Tag format: v1.2.3, 1.2.3, release (with hash)
  Nightly      Tag format: nightly, continuous, canary (no hash)
  Dev/Preview  Pre-release GitHub releases (no hash)

Features:
  - Auto-detects platform (emulator type) if applicable
  - Downloads asset and monitors for portable data
  - Calculates or retrieves SHA256 checksums
  - Generates checkver and autoupdate configs
  - Proper hash handling for nightly/dev builds
  - GitHub issue integration with auto-comments

'@

$sessionIsNonInteractive = Get-NonInteractivePreference -Override:$NonInteractive

if (-not $RepoUrl -and -not $IssueNumber) {
    if ($sessionIsNonInteractive) {
        $infoMessage | Write-Status -Level Info
        exit 0
    }

    # Interactive mode: Prompt for URL
    do {
        $RepoUrl = Read-Host "Enter Repository URL (GitHub, GitLab, SourceForge)"
        if (-not (Test-RepoUrl $RepoUrl)) {
            "Invalid URL. Please enter a valid GitHub, GitLab, or SourceForge URL." | Write-Status -Level Warn
        }
    } until (Test-RepoUrl $RepoUrl)
} elseif ($RepoUrl -and -not (Test-RepoUrl $RepoUrl)) {
    if ($sessionIsNonInteractive) {
        throw "Invalid Repository URL provided: $RepoUrl"
    }

    "Invalid Repository URL: $RepoUrl" | Write-Status -Level Warn
    do {
        $RepoUrl = Read-Host "Enter Repository URL (GitHub, GitLab, SourceForge)"
        if (-not (Test-RepoUrl $RepoUrl)) {
            "Invalid URL. Please enter a valid GitHub, GitLab, or SourceForge URL." | Write-Status -Level Warn
        }
    } until (Test-RepoUrl $RepoUrl)
}

try {
    '========================================' | Write-Status -Level Step
    'Scoop Manifest Creator' | Write-Status -Level Step
    '========================================' | Write-Status -Level Step

    $issueInfo = $null
    if ($IssueNumber) {
        '' | Write-Status
        'Processing GitHub issue...' | Write-Status -Level Step

        if (-not $GitHubToken) {
            throw 'GitHubToken is required when using -IssueNumber. Provide a GitHub personal access token.'

        }

        $issueInfo = Get-IssueMetadata -IssueNumber $IssueNumber -Token $GitHubToken
        $RepoUrl = $issueInfo.RepoUrl

        "Issue: $($issueInfo.IssueTitle)" | Write-Status -Level OK
        "Repository URL extracted: $($issueInfo.RepoUrl)" | Write-Status -Level OK
    } else {
        if (-not $RepoUrl) {
            throw 'Either -RepoUrl or -IssueNumber must be provided'
        }
    }

    '' | Write-Status
    'Fetching repository information...' | Write-Status -Level Step

    $repoInfo = if ($RepoUrl -match 'github\.com') {
        Get-GitHubReleaseInfo -Url $RepoUrl
    } elseif ($RepoUrl -match 'gitlab\.com') {
        Get-GitLabReleaseInfo -Url $RepoUrl
    } elseif ($RepoUrl -match 'sourceforge\.net') {
        Get-SourceForgeReleaseInfo -Url $RepoUrl -NonInteractive:$sessionIsNonInteractive
    } else {
        throw "Unsupported repository URL: $RepoUrl. Supported platforms: GitHub, GitLab, SourceForge."
    }

    "Repository: $($repoInfo.Owner)/$($repoInfo.Repo)" | Write-Status -Level OK
    "Latest version: $($repoInfo.Version)" | Write-Status -Level OK

    '' | Write-Status
    'Fetching repository metadata...' | Write-Status -Level Step
    $metadata = Get-RepositoryInfo -Owner $repoInfo.Owner -Repo $repoInfo.Repo -Platform $repoInfo.Platform

    '' | Write-Status
    'Finding architecture assets...' | Write-Status -Level Step
    $archAssets = Select-ArchitectureAssets -Assets $repoInfo.Assets

    $primaryAsset = $archAssets['64bit']
    if (-not $primaryAsset) {
        $primaryAsset = $archAssets['32bit']
    }

    if (-not $primaryAsset) {
        throw "No suitable Windows assets found (checked x64 and x86)"
    }

    "Primary Asset: $($primaryAsset.name) (Size: $([math]::Round($primaryAsset.size / 1MB, 2)) MB)" | Write-Status -Level OK

    '' | Write-Status
    'Downloading and processing primary asset...' | Write-Status -Level Step
    $tempDir = Join-Path $env:TEMP "manifest-creator-$(Get-Random)"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $downloadPath = Get-AssetContent -Asset $primaryAsset -OutputDirectory $tempDir

    $executablePath = $null
    $executableName = $null
    $licenseFile = $null
    $dependencies = @()
    $extractDirName = $null
    $notes = @()
    $auxBinaries = @()

    if ($primaryAsset.name -match '\.exe$') {
        $executablePath = $downloadPath
        $executableName = Split-Path -Leaf $downloadPath
    } else {
        $extractDir = Join-Path $tempDir 'extracted'
        Expand-Asset -ArchivePath $downloadPath -ExtractDirectory $extractDir
        # Clean repo name by removing CI, Dev, Nightly suffixes for executable search
        $cleanedRepoName = $repoInfo.Repo -replace '(?i)([-_]?(ci|dev|nightly))$', ''
        $executable = Find-Executable -SearchDirectory $extractDir -ProjectName $cleanedRepoName -NonInteractive:$NonInteractive
        $executablePath = $executable.FullName
        $executableName = $executable.Name

        $extractDirName = Get-ExtractDir -Directory $extractDir

        $licenseFile = Find-LicenseFile -SearchDirectory $extractDir
        if ($licenseFile) {
            "License file found: $licenseFile" | Write-Status -Level OK
        }

        $dependencies = Find-Dependencies -SearchDirectory $extractDir
        if ($dependencies) {
            "Dependencies detected: $($dependencies -join ', ')" | Write-Status -Level OK
        }

        $notes = Find-Notes -Directory $extractDir
        $auxBinaries = Find-AuxiliaryBinaries -Directory $extractDir -MainExecutableName $executableName
        if ($auxBinaries) {
            "Auxiliary binaries found: $($auxBinaries -join ', ')" | Write-Status -Level Info
        }
    }

    "Executable: $executableName" | Write-Status -Level OK

    # Check if the selected executable is actually an installer
    $installerType = Test-InstallerType -FilePath $executablePath
    if ($installerType) {
        '' | Write-Status
        '========================================' | Write-Status -Level Warn
        "WARNING: The selected executable appears to be an installer ($installerType)" | Write-Status -Level Warn
        '========================================' | Write-Status -Level Warn
        'Scoop manifests should ideally extract the application rather than running an installer.' | Write-Status -Level Info
        'Consider using "innosetup" or "lessmsi" to extract the contents.' | Write-Status -Level Info
        '' | Write-Status
    }

    '' | Write-Status
    'Monitoring application execution...' | Write-Status -Level Step
    $persistResult = Test-PortableMode -ExecutablePath $executablePath -WorkingDirectory (Split-Path $executablePath) -IsNonInteractive $sessionIsNonInteractive

    '' | Write-Status
    'Building manifest...' | Write-Status -Level Step
    $platform = Find-EmulatorPlatform -RepositoryName $repoInfo.Repo -Description $metadata.Description
    if ($platform) {
        "Detected platform: $platform" | Write-Status -Level OK
    } else {
        'Not an emulator, using repository description' | Write-Status -Level Info
    }

    # Calculate checksums for all architectures
    foreach ($arch in $archAssets.Keys) {
        $asset = $archAssets[$arch]

        # If this is the primary asset we already downloaded, calculate hash locally
        if ($asset.name -eq $primaryAsset.name) {
            $asset | Add-Member -MemberType NoteProperty -Name 'FilePath' -Value $downloadPath -Force
        }

        $releaseChecksum = Get-ReleaseChecksum -Assets $repoInfo.Assets -TargetAssetName $asset.name
        if ($releaseChecksum) {
            "[$arch] Using checksum from release files" | Write-Status -Level OK
            $asset | Add-Member -MemberType NoteProperty -Name 'Checksum' -Value $releaseChecksum -Force
            $asset | Add-Member -MemberType NoteProperty -Name 'HasChecksumFile' -Value $true -Force
        } else {
            if ($asset.name -eq $primaryAsset.name) {
                "[$arch] Calculating hash from downloaded file..." | Write-Status -Level Info
                $calculatedHash = ConvertTo-FileHash -FilePath $downloadPath
                $asset | Add-Member -MemberType NoteProperty -Name 'Checksum' -Value $calculatedHash -Force
                $asset | Add-Member -MemberType NoteProperty -Name 'HasChecksumFile' -Value $false -Force
            } else {
                "[$arch] No checksum file found and asset not downloaded - skipping hash verification for non-primary architecture" | Write-Status -Level Warn
                # For non-primary assets without checksum files, we can't easily get the hash without downloading
                # In a real scenario we might want to download these too, but for now we'll skip or mark as missing
            }
        }
    }

    $persistItemsToUse = $persistResult.Items
    $usesStandardFolders = $persistResult.UsesStandardFolders

    if (-not $persistResult.HasPersist) {
        '' | Write-Status
        '========================================' | Write-Status -Level Warn
        'WARNING - No Persist Folders Detected' | Write-Status -Level Warn
        '========================================' | Write-Status -Level Warn
        'The application was launched, but no data was saved to' | Write-Status -Level Warn
        'the ''user'' or ''portable'' folders.' | Write-Status -Level Warn
        '' | Write-Status
        'This means:' | Write-Status -Level Info
        '  - Settings will NOT be preserved on updates' | Write-Status -Level Warn
        '  - Save files and configs will be LOST' | Write-Status -Level Warn
        '  - Each installation starts with default settings' | Write-Status -Level Warn
        '' | Write-Status
        'Options:' | Write-Status -Level Info
        '  1) Continue without persist (data loss risk)' | Write-Status -Level Warn
        '  2) Re-run the application to capture configuration' | Write-Status -Level Info
        '' | Write-Status

        $choice = 'continue'
        if (-not $sessionIsNonInteractive) {
            try {
                do {
                    $inputChoice = Read-Host 'What would you like to do? (continue/rerun)'
                    if ($inputChoice -match '^(continue|rerun|1|2)$') {
                        $choice = $inputChoice
                        break
                    }
                    "Invalid choice. Please enter 'continue' (1) or 'rerun' (2)." | Write-Status -Level Warn
                } while ($true)
            } catch {
                'Error reading input, continuing without persist' | Write-Status -Level Warn
            }
        } else {
            'Non-interactive mode detected, continuing without persist' | Write-Status -Level Info
        }
        '' | Write-Status

        if ($choice -eq 'rerun' -or $choice -eq '2') {
            'Re-running executable for persist configuration...' | Write-Status -Level Info
            $retryResult = Test-PortableMode -ExecutablePath $executablePath -WorkingDirectory (Split-Path $executablePath) -IsNonInteractive $sessionIsNonInteractive
            $persistItemsToUse = $retryResult.Items
            $usesStandardFolders = $retryResult.UsesStandardFolders
            if ($retryResult.HasPersist) {
                'Persist folders detected on retry' | Write-Status -Level OK
            } else {
                'Still no persist folders. Continuing without persist.' | Write-Status -Level Warn
            }
        } else {
            'Continuing without persist configuration' | Write-Status -Level Info
        }
    }

    $manifest = New-ScoopManifest `
        -RepositoryInfo $repoInfo `
        -ArchitectureAssets $archAssets `
        -ExecutableName $executableName `
        -PersistItems $persistItemsToUse `
        -Metadata $metadata `
        -Platform $platform `
        -BuildType $repoInfo.BuildType `
        -UsesStandardFolders $usesStandardFolders `
        -LicenseFile $licenseFile `
        -Dependencies $dependencies `
        -ExtractDir $extractDirName `
        -Notes $notes `
        -AuxiliaryBinaries $auxBinaries

    # Apply user-provided manifest details or use defaults
    $manifestDetails = Request-ManifestDetails `
        -Manifest $manifest `
        -CurrentPersistItems $persistItemsToUse `
        -ProvidedDescription $Description `
        -ProvidedPersistFolders $PersistFolders `
        -ProvidedShortcutName $ShortcutName

    # Update manifest with details
    $manifest['description'] = $manifestDetails.Description
    $manifest['shortcuts'][0][1] = $manifestDetails.ShortcutName

    # Update persist to always be an array
    if ($manifestDetails.PersistItems.Count -gt 0) {
        $manifest['persist'] = @($manifestDetails.PersistItems)
    }

    $bucketDir = Join-Path (Split-Path $PSScriptRoot) 'bucket'
    $manifestPath = Export-Manifest -Manifest $manifest -RepositoryName $repoInfo.Repo -OutputDirectory $bucketDir

    '' | Write-Status
    'Cleaning up temporary files...' | Write-Status -Level Info
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

    '' | Write-Status
    'Validating manifest with Scoop tools...' | Write-Status -Level Step

    # Get cleaned app name for validation (strip suffixes and lowercase)
    $cleanedAppName = $repoInfo.Repo -replace '(?i)([-_]?(ci|dev|nightly))$', ''
    $cleanedAppName = $cleanedAppName.ToLower()

    $bucketDir = Join-Path (Split-Path $PSScriptRoot) 'bucket'
    $validationResult = Invoke-ManifestValidation -ManifestPath $manifestPath -BucketDirectory $bucketDir -AppName $cleanedAppName

    '' | Write-Status
    if ($validationResult.AllPassed) {
        '========================================' | Write-Status -Level OK
        'All validation tests PASSED!' | Write-Status -Level OK
        '========================================' | Write-Status -Level OK
    } else {
        '========================================' | Write-Status -Level Warn
        'Some validation tests FAILED' | Write-Status -Level Warn
        '========================================' | Write-Status -Level Warn
        '' | Write-Status
        'Failed tests:' | Write-Status -Level Error
        foreach ($result in $validationResult.Results | Where-Object { $_.Status -eq 'FAIL' }) {
            "  - $($result.Name): $($result.Message)" | Write-Status -Level Error
        }
        '' | Write-Status
        'Please review the manifest and re-run validation:' | Write-Status -Level Info
        "  .\bin\checkver.ps1 -Dir bucket -App $cleanedAppName" | Write-Status -Level Info
        "  .\bin\check-autoupdate.ps1 -ManifestPath bucket\$cleanedAppName.json" | Write-Status -Level Info
        "  .\bin\check-manifest-install.ps1 -ManifestPath bucket\$cleanedAppName.json" | Write-Status -Level Info
    }

    if ($issueInfo) {
        '' | Write-Status
        'Updating GitHub issue...' | Write-Status -Level Step

        $platformInfo = if ($platform) { "**Platform:** $platform" } else { '**Type:** Application' }
        $validationStatus = if ($validationResult.AllPassed) { '[OK] All validation tests **PASSED**' } else { '[WARN] Some validation tests **FAILED** - please review' }

        $commentText = @(
            '[OK] Manifest created successfully!',
            '',
            "**Repository:** $($repoInfo.Owner)/$($repoInfo.Repo)",
            "**Version:** $($repoInfo.Version)",
            $platformInfo,
            "**Manifest:** ``bucket/$cleanedAppName.json``",
            "**Validation Status:** $validationStatus",
            '',
            'The manifest has been automatically generated based on the latest release. Validation tests have been run automatically.',
            '',
            'To review or re-run validation tests:',
            '',
            '```powershell',
            ".\bin\checkver.ps1 -Dir bucket -App $cleanedAppName",
            ".\bin\check-autoupdate.ps1 -ManifestPath bucket\$cleanedAppName.json",
            ".\bin\check-manifest-install.ps1 -ManifestPath bucket\$cleanedAppName.json",
            '```',
            '',
            'If all tests pass, the manifest is ready for merging.'
        ) -join "`n"

        Update-IssueComment -IssueNumber $issueInfo.IssueNumber -Token $GitHubToken -Comment $commentText -Labels @('manifest-created') -Confirm:$false
    }

    if ($CreatePR) {
        '' | Write-Status
        'Creating Pull Request...' | Write-Status -Level Step
        New-PullRequest -ManifestPath $manifestPath -AppName $cleanedAppName -Version $repoInfo.Version -RepoUrl $repoInfo.RepoUrl
    }

    '' | Write-Status
    '========================================' | Write-Status -Level OK
    'Manifest created successfully!' | Write-Status -Level OK
    '========================================' | Write-Status -Level OK
    '' | Write-Status
    'Manifest Details:' | Write-Status -Level Info
    "  Repository: $($repoInfo.Owner)/$($repoInfo.Repo)" | Write-Status -Level Info
    "  Type: $(if ($platform) { "$platform Emulator" } else { 'Application' })" | Write-Status -Level Info
    "  Version: $($repoInfo.Version)" | Write-Status -Level Info
    "  Location: $manifestPath" | Write-Status -Level Info
    '' | Write-Status
    'Validation Results:' | Write-Status -Level Info
    foreach ($result in $validationResult.Results) {
        $statusStr = switch ($result.Status) {
            'PASS' { '[OK]' }
            'FAIL' { '[FAIL]' }
            'SKIP' { '[SKIP]' }
            default { $result.Status }
        }
        "  $statusStr $($result.Name)" | Write-Status -Level Info
    }
} catch {
    '' | Write-Status
    $_.Exception.Message | Write-Status -Level Error
    "Stack Trace: $($_.ScriptStackTrace)" | Write-Status -Level Error

    if ($issueInfo -and $GitHubToken) {
        try {
            $errorComment = "[FAIL] Failed to create manifest: $($_.Exception.Message)"
            Update-IssueComment -IssueNumber $issueInfo.IssueNumber -Token $GitHubToken -Comment $errorComment -Labels @('needs-investigation') -Confirm:$false
        } catch {
            'Could not update GitHub issue with error info' | Write-Status -Level Warn
        }
    }

    exit 1
}

#endregion
