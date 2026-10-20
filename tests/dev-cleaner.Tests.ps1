# Run with: pwsh -NoProfile -c 'Invoke-Pester tests'

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' 'dev-cleaner.ps1'
}

Describe 'dev-cleaner.ps1 harness' {
    It 'dot-sourcing defines functions without starting the menu' {
        # Child process with no stdin: if the entry point runs, Read-Host fails
        # or the menu output shows up instead of the function type.
        $out = '' | pwsh -NoProfile -NonInteractive -Command ". '$script:ScriptPath'; (Get-Command Format-Size).CommandType" 2>&1
        ($out | Out-String).Trim() | Should -Be 'Function'
    }

    It 'still handles -Version when executed' {
        $out = pwsh -NoProfile -NonInteractive -File $script:ScriptPath -Version 2>&1
        ($out | Out-String) | Should -Match 'v1\.2\.0'
    }
}
