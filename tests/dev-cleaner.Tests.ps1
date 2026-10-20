# Run with: pwsh -NoProfile -c 'Invoke-Pester tests'

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..' 'dev-cleaner.ps1'
    . $script:ScriptPath

    function New-TestFile([string]$Path, [int]$Kb = 1) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [IO.File]::WriteAllBytes($Path, [byte[]]::new($Kb * 1024))
    }

    function New-TestRepo([string]$Path, [string]$Remote = 'git@github.com:acme/app.git') {
        git init -q -b main $Path
        git -C $Path config user.email test@example.com
        git -C $Path config user.name Test
        git -C $Path config commit.gpgsign false
        git -C $Path commit -q --allow-empty -m init
        git -C $Path remote add origin $Remote
    }

    function Real([string]$Path) { (Resolve-Path -LiteralPath $Path).ProviderPath }
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
        ($out | Out-String) | Should -Match 'v1\.3\.0'
    }
}

Describe 'Remove-SafelyWithTracking' {
    BeforeEach { $script:DryRun = $false; $script:FailedItems.Clear() }

    It 'keeps the path under -DryRun and says so' {
        New-TestFile "$TestDrive/cache/blob"
        $script:DryRun = $true
        $out = Remove-SafelyWithTracking -Path "$TestDrive/cache" -Description 'cache' 6>&1
        "$TestDrive/cache/blob" | Should -Exist
        ($out | Out-String) | Should -Match '\[DRY-RUN\] Would delete'
    }

    It 'deletes when not in dry-run' {
        New-TestFile "$TestDrive/cache2/blob"
        Remove-SafelyWithTracking -Path "$TestDrive/cache2" -Description 'cache' 6>&1 | Out-Null
        "$TestDrive/cache2" | Should -Not -Exist
    }

    It 'refuses empty, root and home paths' {
        foreach ($p in @('', '/', $HOME, "$HOME/")) {
            Remove-SafelyWithTracking -Path $p -Description 'x' 6>&1 | Out-Null
        }
        $script:FailedItems.Count | Should -Be 4
        $HOME | Should -Exist
    }
}

Describe 'Resolve-ProjectRoots' {
    BeforeEach { Remove-Item Env:DEV_CLEANER_PROJECT_DIRS -ErrorAction SilentlyContinue }

    It 'defaults to the current directory' {
        Push-Location $TestDrive
        try { Resolve-ProjectRoots 3>$null } finally { Pop-Location }
        $script:ProjectRoots | Should -Be @((Real $TestDrive))
        $script:ProjectsDirSource | Should -Be 'default'
    }

    It 'reads DEV_CLEANER_PROJECT_DIRS split on the platform path separator' {
        New-Item -ItemType Directory "$TestDrive/a", "$TestDrive/b" -Force | Out-Null
        $env:DEV_CLEANER_PROJECT_DIRS = "$TestDrive/a$([IO.Path]::PathSeparator)$TestDrive/b$([IO.Path]::PathSeparator)$TestDrive/missing"
        Resolve-ProjectRoots 3>$null
        $script:ProjectRoots | Should -Be @((Real "$TestDrive/a"), (Real "$TestDrive/b"))
        $script:ProjectsDirSource | Should -Be 'environment'
    }

    It 'explicit dirs win and nested or duplicate roots are dropped' {
        New-Item -ItemType Directory "$TestDrive/r/worksets", "$TestDrive/r-old" -Force | Out-Null
        $env:DEV_CLEANER_PROJECT_DIRS = "$TestDrive/r-old"
        Resolve-ProjectRoots -Dirs "$TestDrive/r/worksets", "$TestDrive/r", "$TestDrive/r", "$TestDrive/r-old"
        $script:ProjectRoots | Should -Be @((Real "$TestDrive/r"), (Real "$TestDrive/r-old"))
        $script:ProjectsDirSource | Should -Be 'command-line'
    }
}

Describe 'node_modules and .NET output' {
    BeforeEach {
        $script:DryRun = $false
        $R = "$TestDrive/repos-$([guid]::NewGuid())"
        New-TestFile "$R/web/package.json"
        New-TestFile "$R/web/src/index.js"
        New-TestFile "$R/web/node_modules/lodash/node_modules/x/index.js" 8
        New-TestFile "$R/web/bin/run.sh"
        New-TestFile "$R/tools/node_modules/orphan/index.js"
        New-TestFile "$R/.vscode/extensions/ext/package.json"
        New-TestFile "$R/.vscode/extensions/ext/node_modules/d/index.js"
        New-TestFile "$R/AppData/Roaming/npm/package.json"
        New-TestFile "$R/AppData/Roaming/npm/node_modules/d/index.js"
        New-TestFile "$R/api/Api.sln"
        New-TestFile "$R/api/.vs/Api/v17/.suo"
        New-TestFile "$R/api/src/Api/Api.csproj"
        New-TestFile "$R/api/src/Api/Program.cs"
        New-TestFile "$R/api/src/Api/bin/Debug/Api.dll" 8
        New-TestFile "$R/api/src/Api/obj/project.assets.json"
        New-TestFile "$R/api/src/Lib/Lib.fsproj"
        New-TestFile "$R/api/src/Lib/obj/x"
        $R = Real $R
    }

    It 'Get-NodeModulesDirs returns top-level node_modules next to a package.json only' {
        @(Get-NodeModulesDirs -Roots $R) | Should -Be @((Join-Path $R 'web/node_modules'))
    }

    It 'Clear-NodeModules deletes them and keeps sources' {
        Clear-NodeModules -Roots $R 6>&1 | Out-Null
        "$R/web/node_modules" | Should -Not -Exist
        "$R/web/package.json" | Should -Exist
        "$R/tools/node_modules" | Should -Exist
        "$R/.vscode/extensions/ext/node_modules" | Should -Exist
        "$R/AppData/Roaming/npm/node_modules" | Should -Exist
    }

    It 'Clear-NodeModules under -DryRun deletes nothing' {
        $script:DryRun = $true
        Clear-NodeModules -Roots $R 6>&1 | Out-Null
        "$R/web/node_modules" | Should -Exist
    }

    It 'Clear-VisualStudio removes bin/obj next to C#/F# projects and .vs next to solutions' {
        Clear-VisualStudio -SearchDir $R 6>&1 | Out-Null
        "$R/api/src/Api/bin" | Should -Not -Exist
        "$R/api/src/Api/obj" | Should -Not -Exist
        "$R/api/src/Lib/obj" | Should -Not -Exist
        "$R/api/.vs" | Should -Not -Exist
        "$R/api/src/Api/Program.cs" | Should -Exist
        "$R/web/bin/run.sh" | Should -Exist
    }
}

Describe 'Playwright' {
    BeforeEach {
        $script:DryRun = $false
        Remove-Item Env:PLAYWRIGHT_BROWSERS_PATH -ErrorAction SilentlyContinue
        $env:LOCALAPPDATA = "$TestDrive/local"
    }

    It 'lives under LOCALAPPDATA, or PLAYWRIGHT_BROWSERS_PATH when set' {
        Get-PlaywrightCacheDir | Should -Be (Join-Path "$TestDrive/local" 'ms-playwright')
        $env:PLAYWRIGHT_BROWSERS_PATH = "$TestDrive/pw"
        Get-PlaywrightCacheDir | Should -Be "$TestDrive/pw"
        $env:PLAYWRIGHT_BROWSERS_PATH = '0'
        Get-PlaywrightCacheDir | Should -BeNullOrEmpty
    }

    It 'Clear-Playwright empties the cache and keeps the directory' {
        New-TestFile "$TestDrive/local/ms-playwright/chromium-1/chrome" 8
        Clear-Playwright 6>&1 | Out-Null
        "$TestDrive/local/ms-playwright" | Should -Exist
        @(Get-ChildItem "$TestDrive/local/ms-playwright" -Force).Count | Should -Be 0
    }
}

Describe 'Worktrees' {
    BeforeAll {
        function Set-Pr([string]$Branch, [string]$State) { $script:PrStates[$Branch] = $State }
    }

    BeforeEach {
        $script:DryRun = $false
        $script:AssumeYes = $false
        $script:PrStates = @{}
        $script:Answers = [System.Collections.Generic.Queue[string]]::new()
        Mock Test-GhReady { $true }
        Mock Get-PrState { param($Slug, $Branch) if ($script:PrStates.ContainsKey($Branch)) { $script:PrStates[$Branch] } else { 'NONE' } }
        Mock Confirm-Action { if ($script:Answers.Count) { $script:Answers.Dequeue() -eq 'y' } else { $false } }

        $base = "$TestDrive/wt-$([guid]::NewGuid())"
        New-TestRepo "$base/repos/app"
        git -C "$base/repos/app" worktree add -q -b T-1/merged "$base/repos/worksets/T-1/app" 2>$null
        Resolve-ProjectRoots -Dirs "$base/repos"
        $R = $script:ProjectRoots[0]
        $WT = Join-Path $R 'worksets/T-1/app'
    }

    It 'ConvertTo-GitHubSlug parses GitHub remotes only' {
        ConvertTo-GitHubSlug 'git@github.com:acme/app.git' | Should -Be 'acme/app'
        ConvertTo-GitHubSlug 'https://github.com/acme/app' | Should -Be 'acme/app'
        ConvertTo-GitHubSlug 'ssh://git@github.com/acme/app.git' | Should -Be 'acme/app'
        ConvertTo-GitHubSlug 'git@gitlab.com:acme/app.git' | Should -BeNullOrEmpty
    }

    It 'Get-WorktreeAction maps PR state and dirtiness' {
        Get-WorktreeAction 'MERGED' $false | Should -Be 'remove'
        Get-WorktreeAction 'CLOSED' $false | Should -Be 'warn'
        Get-WorktreeAction 'OPEN' $false | Should -Be 'skip'
        Get-WorktreeAction 'MERGED' $true | Should -Be 'skip-dirty'
    }

    It 'Get-Worktrees lists linked worktrees and skips detached and locked ones' {
        git -C "$R/app" worktree add -q --detach "$R/worksets/T-2/app" 2>$null
        git -C "$R/app" worktree add -q -b locked-one "$R/worksets/T-3/app" 2>$null
        git -C "$R/app" worktree lock "$R/worksets/T-3/app"
        $wts = @(Get-Worktrees -Roots $R)
        $wts.Count | Should -Be 1
        $wts[0].Branch | Should -Be 'T-1/merged'
        $wts[0].Main | Should -Be (Join-Path $R 'app')
    }

    It 'removes a merged worktree and its branch after confirmation' {
        Set-Pr 'T-1/merged' 'MERGED'
        $script:Answers.Enqueue('y')
        Clear-Worktrees 6>&1 | Out-Null
        $WT | Should -Not -Exist
        git -C "$R/app" branch --list 'T-1/merged' | Should -BeNullOrEmpty
    }

    It '-Yes removes merged but never CLOSED worktrees' {
        Set-Pr 'T-1/merged' 'CLOSED'
        $script:AssumeYes = $true
        Clear-Worktrees 6>&1 | Out-Null
        $WT | Should -Exist
    }

    It 'never offers a dirty or open worktree' {
        Set-Pr 'T-1/merged' 'MERGED'
        Set-Content "$WT/notes.txt" 'wip'
        $script:AssumeYes = $true
        Clear-Worktrees 6>&1 | Out-Null
        "$WT/notes.txt" | Should -Exist
        Remove-Item "$WT/notes.txt"
        Set-Pr 'T-1/merged' 'OPEN'
        Clear-Worktrees 6>&1 | Out-Null
        $WT | Should -Exist
    }

    It 'keeps an unmerged branch and still removes the worktree' {
        Set-Pr 'T-1/merged' 'MERGED'
        git -C $WT commit -q --allow-empty -m 'squash-merged upstream'
        $script:AssumeYes = $true
        $out = Clear-Worktrees 6>&1 | Out-String
        $WT | Should -Not -Exist
        git -C "$R/app" branch --list 'T-1/merged' | Should -Not -BeNullOrEmpty
        $out | Should -Match 'Kept branch T-1/merged'
    }

    It 'removes an emptied parent folder but keeps one with other files' {
        git -C "$R/app" worktree add -q -b T-2/merged "$R/worksets/T-2/app" 2>$null
        Set-Content "$R/worksets/T-2/ticket.md" 'ticket'
        Set-Pr 'T-1/merged' 'MERGED'
        Set-Pr 'T-2/merged' 'MERGED'
        $script:AssumeYes = $true
        Clear-Worktrees 6>&1 | Out-Null
        "$R/worksets/T-1" | Should -Not -Exist
        "$R/worksets/T-2/ticket.md" | Should -Exist
    }

    It 'dry-run removes nothing' {
        Set-Pr 'T-1/merged' 'MERGED'
        $script:DryRun = $true
        $out = Clear-Worktrees 6>&1 | Out-String
        $WT | Should -Exist
        $out | Should -Match 'Would remove worktree'
    }

    It 'does nothing without an authenticated gh' {
        Mock Test-GhReady { $false }
        Set-Pr 'T-1/merged' 'MERGED'
        $script:AssumeYes = $true
        $out = Clear-Worktrees 6>&1 | Out-String
        $WT | Should -Exist
        $out | Should -Match 'Skipping'
    }
}

Describe 'Clear All and -Only' {
    BeforeEach {
        Mock Invoke-Cleanup { param($Key) $script:Ran.Add($Key) }
        $script:Ran = [System.Collections.Generic.List[string]]::new()
    }

    It 'Clear All includes node_modules and Playwright, never worktrees' {
        $script:ProjectsDirSource = 'command-line'
        Invoke-ClearAll 6>&1 | Out-Null
        $script:Ran | Should -Contain 'node_modules'
        $script:Ran | Should -Contain 'playwright'
        $script:Ran | Should -Contain 'visualstudio'
        $script:Ran | Should -Not -Contain 'worktrees'
    }

    It 'Clear All skips node_modules with only the default root' {
        $script:ProjectsDirSource = 'default'
        Invoke-ClearAll 6>&1 | Out-Null
        $script:Ran | Should -Not -Contain 'node_modules'
        $script:Ran | Should -Contain 'playwright'
    }

    It 'every cleanup key is handled by Invoke-Cleanup' {
        $body = (Get-Content $script:ScriptPath -Raw)
        foreach ($key in $script:CleanupKeys) {
            $body | Should -Match "`"$key`" \{"
        }
    }
}

Describe '-Only from the command line' {
    BeforeAll {
        function Invoke-Script([string[]]$ScriptArgs) {
            $out = '' | pwsh -NoProfile -NonInteractive -File $script:ScriptPath @ScriptArgs 2>&1
            [PSCustomObject]@{ Code = $LASTEXITCODE; Out = ($out | Out-String) }
        }
    }

    It 'runs dry-run cleanups without a terminal' {
        $env:LOCALAPPDATA = "$TestDrive/local"
        New-TestFile "$TestDrive/local/ms-playwright/chromium-1/chrome"
        $r = Invoke-Script @('-Only', 'playwright', '-DryRun')
        $r.Code | Should -Be 0
        $r.Out | Should -Match 'Would delete'
        "$TestDrive/local/ms-playwright/chromium-1/chrome" | Should -Exist
    }

    It 'rejects unknown keys' {
        $r = Invoke-Script @('-Only', 'node_modules,foo', '-DryRun')
        $r.Code | Should -Be 2
        $r.Out | Should -Match 'Unknown cleanup: foo'
    }

    It 'refuses to delete without a terminal unless -Yes is given' {
        New-TestFile "$TestDrive/cli/web/package.json"
        New-TestFile "$TestDrive/cli/web/node_modules/x/index.js"
        $r = Invoke-Script @('-Only', 'node_modules', '-ProjectsDir', "$TestDrive/cli")
        $r.Code | Should -Be 1
        "$TestDrive/cli/web/node_modules" | Should -Exist
        $r = Invoke-Script @('-Only', 'node_modules', '-ProjectsDir', "$TestDrive/cli", '-Yes')
        $r.Code | Should -Be 0
        "$TestDrive/cli/web/node_modules" | Should -Not -Exist
    }

    It 'refuses -DryRun for cleanups that cannot honour it' {
        $r = Invoke-Script @('-Only', 'npm', '-DryRun')
        $r.Code | Should -Be 1
        $r.Out | Should -Match 'DryRun'
    }
}
