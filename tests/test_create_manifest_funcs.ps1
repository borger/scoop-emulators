function Write-Status { param($Message, [string]$Level='Info') Write-Host "${Level}: $Message" }

function Test-RepoUrl { param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    if ($Url -match 'github\.com/[^/]+/[^/]+') { return $true }
    if ($Url -match 'gitlab\.com/[^/]+/[^/]+') { return $true }
    if ($Url -match 'sourceforge\.net/projects/[^/]+') { return $true }
    return $false
}

function Test-NightlyBuild { param([string]$TagName)
    if ($TagName -match 'nightly|continuous|dev|canary') { return $true }
    $nightlyPatterns = @('latest','main','master','trunk')
    return $nightlyPatterns -contains ($TagName.ToLower())
}

function Get-AssetScore { param([string]$Name)
    $score = 0; $n = $Name.ToLower()
    if ($n -match '\.zip$') { $score += 100 } elseif ($n -match '\.7z$') { $score += 90 } elseif ($n -match '\.tar\.gz$|\.tgz$') { $score += 80 } elseif ($n -match '\.jar$') { $score += 60 } elseif ($n -match '\.exe$') { $score += 0 } else { return -1 }
    if ($n -match 'sdl2') { $score += 50 }
    if ($n -match 'msys2|mingw') { $score += 40 }
    if ($n -match 'qt6') { $score += 30 }
    if ($n -match 'qt5') { $score += 20 }
    if ($n -match 'portable') { $score += 20 }
    if ($n -match 'msvc') { $score -= 20 }
    if ($n -match 'debug|symbols|pdb') { $score -= 100 }
    if ($n -match 'installer|setup') { $score -= 50 }
    return $score
}

function Select-ArchitectureAssets { param([object[]]$Assets)
    $archPatterns = @{'64bit' = 'x64|x86_64|amd64|win64'; '32bit' = 'x86|win32|ia32'; 'arm64' = 'arm64|aarch64'}
    $archMap = @{}
    foreach ($arch in $archPatterns.Keys) {
        $pattern = $archPatterns[$arch]
        $candidates = @($Assets | Where-Object { $_.name -match 'windows|win' -and $_.name -match $pattern })
        if ($candidates.Count -gt 0) {
            $best = $candidates | Select-Object @{N='Asset';E={$_}}, @{N='Score';E={ Get-AssetScore $_.name }} |
                Sort-Object Score -Descending | Select-Object -First 1
            if ($best.Score -ge 0) { $archMap[$arch] = $best.Asset }
        }
    }
    return $archMap
}

# Tests
Write-Host 'Test-RepoUrl github:' (Test-RepoUrl -Url 'https://github.com/owner/repo')
Write-Host 'Test-RepoUrl gitlab:' (Test-RepoUrl -Url 'https://gitlab.com/owner/repo')
Write-Host 'Test-RepoUrl sf:' (Test-RepoUrl -Url 'https://sourceforge.net/projects/project')
Write-Host 'Test-NightlyBuild nightly:' (Test-NightlyBuild -TagName 'nightly')
Write-Host 'Test-NightlyBuild main:' (Test-NightlyBuild -TagName 'main')
Write-Host 'Get-AssetScore zip:' (Get-AssetScore -Name 'app-win-x64.zip')
Write-Host 'Get-AssetScore exe:' (Get-AssetScore -Name 'installer.exe')
$assets = @(@{name='app-win-x64.zip'; size=1024*1024*50}, @{name='app-win-x86.zip'; size=1024*1024*30}, @{name='app-mac.dmg'; size=1024*1024*40})
$sel = Select-ArchitectureAssets -Assets $assets
Write-Host 'Select-ArchitectureAssets keys:' ($sel.Keys -join ',')
