<#
Shared checksum and hash helper functions used by multiple scripts.
This file centralizes Get-ReleaseChecksum, Get-RemoteFileHash and ConvertTo-FileHash
to avoid duplication across scripts (create-manifest, update-manifest, autofix-manifest).
#>

function Get-ReleaseChecksum {
    [CmdletBinding()]
    param(
        [object[]]$Assets,
        [string]$TargetAssetName
    )

    if (-not $Assets -or [string]::IsNullOrWhiteSpace($TargetAssetName)) { return $null }

    # Common checksum filenames we consider
    $checksumPatterns = @('*.sha256', '*.sha256sum', '*.sha256.txt', '*.checksum', '*.hashes', '*.DIGEST', '*.md5', '*.md5sum')
    $checksumAssets = @()

    foreach ($pattern in $checksumPatterns) {
        $checksumAssets += @($Assets | Where-Object { $_.name -like $pattern })
    }

    if ($checksumAssets.Count -eq 0) { return $null }

    foreach ($checksumAsset in $checksumAssets) {
        try {
            $ProgressPreference = 'SilentlyContinue'

            # Prefer invoking REST method for direct textual content when possible
            $content = $null
            if ($checksumAsset.browser_download_url) {
                try {
                    $content = Invoke-RestMethod -Uri $checksumAsset.browser_download_url -ErrorAction Stop
                } catch {
                    # Fallback to using Invoke-WebRequest and temp file for binary-like responses
                    $tempFile = [System.IO.Path]::GetTempFileName()
                    try {
                        Invoke-WebRequest -Uri $checksumAsset.browser_download_url -OutFile $tempFile -ErrorAction Stop -UseBasicParsing | Out-Null
                        $content = Get-Content -Path $tempFile -Raw
                    } finally {
                        if (Test-Path $tempFile) { Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue }
                    }
                }
            } else {
                # If no download URL provided, attempt to use asset.url
                try { $content = Invoke-RestMethod -Uri $checksumAsset.url -ErrorAction Stop } catch { continue }
            }

            if (-not $content) { continue }

            if ($content -isnot [string]) { $content = $content | Out-String }

            $lines = $content -split "`n" | Where-Object { $_ -match '\S' }

            foreach ($line in $lines) {
                if ($line -match '^([a-f0-9]{64})\s+(.+?)$' -or $line -match '^(.+?)\s+([a-f0-9]{64})$') {
                    $firstValue = $matches[1]
                    $secondValue = $matches[2]
                    if ($firstValue -match '^[a-f0-9]{64}$') {
                        $hash = $firstValue
                        $filename = $secondValue
                    } else {
                        $hash = $secondValue
                        $filename = $firstValue
                    }

                    $hash = $hash.ToLowerInvariant()
                    $filename = $filename.Trim().Trim('*')
                    $checksumFileName = [System.IO.Path]::GetFileName($filename)
                    $targetFileName = [System.IO.Path]::GetFileName($TargetAssetName)

                    if ($checksumFileName.Equals($targetFileName, [System.StringComparison]::OrdinalIgnoreCase)) {
                        Write-Verbose ('[OK] Found SHA256 from release: {0}' -f $hash)
                        return $hash
                    }
                }
            }
        } catch {
            Write-Verbose ('[WARN] Failed to parse checksum file: {0}' -f $_)
        }
    }

    return $null
}

function Get-RemoteFileHash {
    [CmdletBinding()]
    param([string]$Url)

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $tempFile -ErrorAction Stop -UseBasicParsing | Out-Null
        $hash = (Get-FileHash -Path $tempFile -Algorithm SHA256).Hash.ToLower()
        return $hash
    } catch {
        Write-Verbose ('[WARN] Failed to download or hash remote file: {0}' -f $_)
        return $null
    } finally {
        if (Test-Path $tempFile) { Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue }
    }
}

function ConvertTo-FileHash {
    [CmdletBinding()]
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) { throw "File not found: $FilePath" }
    $hash = Get-FileHash -Path $FilePath -Algorithm SHA256
    return $hash.Hash.ToLower()
}

function Get-ScoopHome {
    if ($env:SCOOP_HOME) { return $env:SCOOP_HOME }
    try {
        $path = Convert-Path (scoop prefix scoop)
        if ($path) { return $path }
    } catch {
        Write-Verbose "Could not resolve Scoop home from 'scoop prefix scoop': $($_.Exception.Message)"
    }
    return "$env:USERPROFILE\scoop\apps\scoop\current"
}

function Get-DirectoryArgumentList {
    [CmdletBinding()]
    param(
        [object[]]$Arguments = @(),

        [Parameter(Mandatory)]
        [string]$DefaultDirectory
    )

    $argumentList = @($Arguments)
    foreach ($argument in $argumentList) {
        if ($argument -ieq '-Dir' -or $argument -like '-Dir:*') {
            return $argumentList
        }
    }

    return @('-Dir', $DefaultDirectory) + $argumentList
}

function Invoke-PowerShellScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [object[]]$ArgumentList = @()
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "PowerShell script not found: $Path"
    }

    $executableName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' }
    $executablePath = Join-Path $PSHOME $executableName
    $output = & $executablePath -NoProfile -ExecutionPolicy Bypass -File $Path @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE

    [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = ($output | Out-String).Trim()
    }
}

