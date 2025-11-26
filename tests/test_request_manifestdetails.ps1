function Write-Status { param($Message, [string]$Level = 'Info') Write-Host "${Level}: $Message" }

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

    # Determine a safe default shortcut label. Manifests may store shortcuts
    # as a nested array (e.g., @(@("exe", "Label"))) or a flat value.
    $finalShortcut = ''
    if ($ProvidedShortcutName) {
        $finalShortcut = $ProvidedShortcutName
    } elseif ($Manifest -and $Manifest.Contains('shortcuts') -and $Manifest['shortcuts']) {
        $shortcutsObj = $Manifest['shortcuts']
        # Handle nested array (@(@('exe','Label'))), flat array (@('exe','Label')), or string
        if ($shortcutsObj -is [System.Array]) {
            if ($shortcutsObj.Count -gt 0) {
                $first = $shortcutsObj[0]
                if ($first -is [System.Array]) {
                    if ($first.Count -ge 2) { $finalShortcut = $first[1] } elseif ($first.Count -ge 1) { $finalShortcut = $first[0] }
                } else {
                    # Flat array of strings
                    if ($shortcutsObj.Count -ge 2) { $finalShortcut = $shortcutsObj[1] } else { $finalShortcut = $shortcutsObj[0] }
                }
            }
        } else {
            # Single string
            $finalShortcut = $shortcutsObj.ToString()
        }
    }

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

# Test cases
$manifest1 = @{ description = 'Test app'; shortcuts = @(@('exe', 'MyLabel')) }
$res1 = Request-ManifestDetails -Manifest $manifest1 -CurrentPersistItems @('user', 'config')
Write-Host "Case1 => Desc: $($res1.Description) Persist: $($res1.PersistItems -join ',') Shortcut: $($res1.ShortcutName)"

$manifest2 = @{ description = 'No shortcuts' }
$res2 = Request-ManifestDetails -Manifest $manifest2 -CurrentPersistItems @() -ProvidedPersistFolders @('data', 'user')
Write-Host "Case2 => Desc: $($res2.Description) Persist: $($res2.PersistItems -join ',') Shortcut: $($res2.ShortcutName)"

$manifest3 = @{ description = 'Flat shortcut'; shortcuts = 'FlatLabel' }
$res3 = Request-ManifestDetails -Manifest $manifest3 -CurrentPersistItems @('abc')
Write-Host "Case3 => Desc: $($res3.Description) Persist: $($res3.PersistItems -join ',') Shortcut: $($res3.ShortcutName)"

$manifest4 = @{ description = 'Provided Name' }
$res4 = Request-ManifestDetails -Manifest $manifest4 -CurrentPersistItems @() -ProvidedShortcutName 'UserProvided'
Write-Host "Case4 => Desc: $($res4.Description) Persist: $($res4.PersistItems -join ',') Shortcut: $($res4.ShortcutName)"
