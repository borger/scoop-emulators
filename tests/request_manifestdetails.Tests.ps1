Describe 'Request-ManifestDetails' {
    BeforeAll {
        . "$PSScriptRoot\TestHelpers.ps1"
        $scriptPath = Join-Path $PSScriptRoot '..\bin\create-manifest.ps1'
        . (Get-TestFunctionScriptBlock -Path $scriptPath -Name 'Request-ManifestDetails')
    }

    It 'uses the manifest description, unique persist items, and nested shortcut label by default' {
        $manifest = @{
            description = 'Test app'
            shortcuts   = @(@('app.exe', 'MyLabel'))
        }

        $result = Request-ManifestDetails -Manifest $manifest -CurrentPersistItems @('user', 'config', 'user')

        $result.Description | Should -Be 'Test app'
        $result.PersistItems | Should -Be @('user', 'config')
        $result.ShortcutName | Should -Be 'MyLabel'
    }

    It 'uses supplied description, persist folders, and shortcut name' {
        $result = Request-ManifestDetails `
            -Manifest @{ description = 'Default' } `
            -CurrentPersistItems @('ignored') `
            -ProvidedDescription 'Provided' `
            -ProvidedPersistFolders @('data', 'user') `
            -ProvidedShortcutName 'UserProvided'

        $result.Description | Should -Be 'Provided'
        $result.PersistItems | Should -Be @('data', 'user')
        $result.ShortcutName | Should -Be 'UserProvided'
    }

    It 'supports a flat shortcut array and a single shortcut string' {
        $flatResult = Request-ManifestDetails -Manifest @{ shortcuts = @('app.exe', 'FlatLabel') } -CurrentPersistItems @()
        $stringResult = Request-ManifestDetails -Manifest @{ shortcuts = 'SingleLabel' } -CurrentPersistItems @()

        $flatResult.ShortcutName | Should -Be 'FlatLabel'
        $stringResult.ShortcutName | Should -Be 'SingleLabel'
    }
}
