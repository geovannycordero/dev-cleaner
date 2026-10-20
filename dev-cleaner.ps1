# -----------------------------------------------------------------------------
# Dev Cleanup Utility - Windows PowerShell Edition
# -----------------------------------------------------------------------------
# Version: 1.3.0
# Platform: Windows (PowerShell 5.1+)
# Repository: https://github.com/jemishavasoya/dev-cleaner
# -----------------------------------------------------------------------------

param(
    [switch]$Help,
    [switch]$Version,
    [string]$FlutterDir,
    [string]$VsDir,
    [string[]]$ProjectsDir,
    [string]$Only,
    [switch]$Yes,
    [switch]$DryRun
)

# --- Global Variables ---
$SCRIPT_VERSION = "1.3.0"
$GITHUB_REPO = "https://github.com/jemishavasoya/dev-cleaner"

# --- Error Tracking ---
$script:FailedItems = [System.Collections.ArrayList]::new()

# --- Run mode ---
# -DryRun is honoured by Remove-SafelyWithTracking and the worktree cleanup;
# Invoke-Only refuses it for cleanups that delete through their own tools.
$script:DryRun = [bool]$DryRun
$script:AssumeYes = [bool]$Yes  # -Yes: confirm the safe choice, never force

# Project roots for node_modules and worktree scans (see Resolve-ProjectRoots)
$script:ProjectRoots = @()
$script:ProjectsDirSource = "default"

# --- Estimation state ---
$script:Estimates = @{}
$script:EstimatesReady = $false

# --- Helper Functions ---

function Show-Logo {
    Write-Host ""
    Write-Host "██████╗ ███████╗██╗    ██╗     ██████╗██╗     ███████╗ █████╗ ███╗   ██╗███████╗██████╗" -ForegroundColor Cyan
    Write-Host "██╔══██╗██╔════╝██║    ██║    ██╔════╝██║     ██╔════╝██╔══██╗████╗  ██║██╔════╝██╔══██╗" -ForegroundColor Cyan
    Write-Host "██║  ██║█████╗  ██║    ██║    ██║     ██║     █████╗  ███████║██╔██╗ ██║█████╗  ██████╔╝" -ForegroundColor Cyan
    Write-Host "██║  ██║██╔══╝  ╚██╗ ██╔╝     ██║     ██║     ██╔══╝  ██╔══██║██║╚██╗██║██╔══╝  ██╔══██╗" -ForegroundColor Cyan
    Write-Host "██████╔╝███████╗ ╚████╔╝      ╚██████╗███████╗███████╗██║  ██║██║ ╚████║███████╗██║  ██║" -ForegroundColor Cyan
    Write-Host "╚═════╝ ╚══════╝  ╚═══╝        ╚═════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-HeaderLine {
    param([string]$Char = "─")
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -lt 1) { $width = 80 }
    } catch {
        $width = 80  # Fallback for non-interactive sessions
    }
    Write-Host ($Char * $width)
}

function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "➤ $Title" -ForegroundColor Blue
    Write-HeaderLine "─"
}

function Write-Item {
    param(
        [string]$Icon,
        [string]$Color,
        [string]$Text
    )
    Write-Host "$Icon $Text" -ForegroundColor $Color
}

function Get-DiskSpace {
    $drive = Get-PSDrive -Name ($PWD.Drive.Name) -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        return "$freeGB GB"
    }
    return "Unknown"
}

# --- Estimation helpers (read-only: never delete anything) ---

function Get-PathSizeBytes {
    param([string[]]$Paths)
    [int64]$total = 0
    foreach ($pattern in $Paths) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $items = Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try {
                if ($item.PSIsContainer) {
                    $sum = (Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
                            Measure-Object -Property Length -Sum).Sum
                    if ($sum) { $total += [int64]$sum }
                } else {
                    $total += [int64]$item.Length
                }
            } catch { }
        }
    }
    return $total
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB)     { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    elseif ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    elseif ($Bytes -ge 1KB) { return ("{0:N0} KB" -f ($Bytes / 1KB)) }
    else                    { return ("{0} B" -f $Bytes) }
}

# Convert a Docker size string (Docker uses DECIMAL units: B/kB/MB/GB/TB,
# e.g. "1.02GB", "728.5MB", "32.8kB", "0B") into bytes, so Docker's own
# self-reported sizes can be summed and fed to Format-Size like every other
# estimate. Suffix order matters: kB/MB/GB/TB all end in "B", so the bare
# "B" case must be checked last. Docker always prints a dot as the decimal
# separator, hence InvariantCulture. Read-only.
function Convert-DockerSize {
    param([string]$Size)
    if ([string]::IsNullOrWhiteSpace($Size)) { return [int64]0 }
    $s = $Size.Trim()
    $ci = [System.Globalization.CultureInfo]::InvariantCulture
    try {
        if     ($s -match '^([\d.]+)TB$') { return [int64]([double]::Parse($Matches[1], $ci) * 1e12) }
        elseif ($s -match '^([\d.]+)GB$') { return [int64]([double]::Parse($Matches[1], $ci) * 1e9) }
        elseif ($s -match '^([\d.]+)MB$') { return [int64]([double]::Parse($Matches[1], $ci) * 1e6) }
        elseif ($s -match '^([\d.]+)kB$') { return [int64]([double]::Parse($Matches[1], $ci) * 1e3) }
        elseif ($s -match '^([\d.]+)B$')  { return [int64][double]::Parse($Matches[1], $ci) }
    } catch { }
    return [int64]0
}

function Set-Estimate {
    param([string]$Key, [string]$Label)
    $script:Estimates[$Key] = $Label
}

# Returns " (Estimate: <label>)" for a stable category key, or "" if not yet
# computed. Keys are strings (not menu numbers) so renumbering stays safe.
function Get-Est {
    param([string]$Key)
    if (-not $script:EstimatesReady) { return "" }
    if ($script:Estimates.ContainsKey($Key) -and $script:Estimates[$Key]) {
        return " (Estimate: $($script:Estimates[$Key]))"
    }
    return ""
}

# --- Admin Elevation Functions ---

function Test-Administrator {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    if (-not (Test-Administrator)) {
        Write-Host "This script requires Administrator privileges." -ForegroundColor Yellow
        Write-Host "Relaunching with elevation..." -ForegroundColor Yellow

        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""

        if ($FlutterDir) { $arguments += " -FlutterDir `"$FlutterDir`"" }
        if ($VsDir) { $arguments += " -VsDir `"$VsDir`"" }
        foreach ($d in $ProjectsDir) { $arguments += " -ProjectsDir `"$d`"" }
        if ($Only) { $arguments += " -Only `"$Only`"" }
        if ($Yes) { $arguments += " -Yes" }
        if ($DryRun) { $arguments += " -DryRun" }

        Start-Process PowerShell -Verb RunAs -ArgumentList $arguments
        exit
    }
}

# --- Error Tracking Functions ---

function Remove-SafelyWithTracking {
    param(
        [string]$Path,
        [string]$Description
    )

    # Never delete these, whatever a caller computed (an empty variable turns
    # "$dir\" into "\", an unset one turns "$HOME\$x" into $HOME).
    $trimmed = "$Path".TrimEnd('\', '/')
    if (-not $trimmed -or $trimmed -eq $HOME.TrimEnd('\', '/') -or $trimmed -match '^[A-Za-z]:$') {
        Write-Item "✕" "Red" "Refusing to delete protected path: '$Path'"
        $script:FailedItems.Add([PSCustomObject]@{
            Path = $Path
            Reason = "Protected path"
        }) | Out-Null
        return
    }

    try {
        if (Test-Path -LiteralPath $Path) {
            if ($script:DryRun) {
                Write-Item "•" "Yellow" "[DRY-RUN] Would delete: $Path ($(Format-Size (Get-PathSizeBytes @($Path))))"
                return
            }
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Item "✓" "Green" "Removed: $Description"
        }
    }
    catch {
        $script:FailedItems.Add([PSCustomObject]@{
            Path = $Path
            Reason = $_.Exception.Message
        }) | Out-Null
    }
}

function Show-FailureSummary {
    if ($script:FailedItems.Count -gt 0) {
        Write-Host ""
        Write-Host "Some items could not be deleted:" -ForegroundColor Yellow
        foreach ($item in $script:FailedItems) {
            Write-Host "  - $($item.Path)" -ForegroundColor Red
            Write-Host "    Reason: $($item.Reason)" -ForegroundColor DarkGray
        }
        Write-Host ""
    }
    $script:FailedItems.Clear()
}

# --- Cleanup Functions ---

function Clear-VisualStudio {
    param([string]$SearchDir = ".")

    Write-Item "✓" "Green" "Cleaning Visual Studio projects from: $SearchDir"

    if (-not (Test-Path $SearchDir)) {
        Write-Item "✕" "Red" "Directory not found: $SearchDir"
        return
    }

    # Project-level cleanup
    $solutionFiles = Get-ChildItem -Path $SearchDir -Filter "*.sln" -Recurse -ErrorAction SilentlyContinue
    $projectFiles = Get-ChildItem -Path $SearchDir -Include "*.csproj", "*.fsproj", "*.vbproj" -File -Recurse -ErrorAction SilentlyContinue

    $cleanedCount = 0

    foreach ($sln in $solutionFiles) {
        $slnDir = $sln.DirectoryName
        Write-Host "  Cleaning solution: $slnDir" -ForegroundColor Cyan

        Remove-SafelyWithTracking -Path (Join-Path $slnDir ".vs") -Description ".vs folder in $slnDir"
        $cleanedCount++
    }

    foreach ($proj in $projectFiles) {
        $projDir = $proj.DirectoryName
        Write-Host "  Cleaning project: $projDir" -ForegroundColor Cyan

        Remove-SafelyWithTracking -Path (Join-Path $projDir "bin") -Description "bin folder in $projDir"
        Remove-SafelyWithTracking -Path (Join-Path $projDir "obj") -Description "obj folder in $projDir"
        $cleanedCount++
    }

    if ($cleanedCount -gt 0) {
        Write-Item "✓" "Green" "Cleaned $cleanedCount Visual Studio project(s)/solution(s)"
    } else {
        Write-Item "ℹ️" "Yellow" "No Visual Studio projects found in: $SearchDir"
    }

    # Global Visual Studio caches
    Write-Item "✓" "Green" "Cleaning global Visual Studio caches..."

    $vsVersions = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\VisualStudio" -Directory -ErrorAction SilentlyContinue
    foreach ($vsVersion in $vsVersions) {
        Remove-SafelyWithTracking -Path "$($vsVersion.FullName)\ComponentModelCache" -Description "ComponentModelCache"
        Remove-SafelyWithTracking -Path "$($vsVersion.FullName)\MEFCacheData" -Description "MEFCacheData"
        Remove-SafelyWithTracking -Path "$($vsVersion.FullName)\Designer\ShadowCache" -Description "Designer ShadowCache"
        Remove-SafelyWithTracking -Path "$($vsVersion.FullName)\ImageLibrary" -Description "ImageLibrary"
    }
}

function Clear-AndroidGradle {
    if (Test-Path "$env:USERPROFILE\.gradle") {
        Write-Item "✓" "Green" "Cleaning Gradle caches..."
        Remove-SafelyWithTracking -Path "$env:USERPROFILE\.gradle\caches" -Description "Gradle caches"
        Remove-SafelyWithTracking -Path "$env:USERPROFILE\.gradle\daemon" -Description "Gradle daemon"
        # Downloaded Gradle distributions; re-fetched on next wrapper run.
        Remove-SafelyWithTracking -Path "$env:USERPROFILE\.gradle\wrapper" -Description "Gradle wrapper distributions"
    } else {
        Write-Item "✕" "Yellow" "Gradle directory not found. Skipping."
    }

    if (Test-Path "$env:USERPROFILE\.android") {
        Write-Item "✓" "Green" "Cleaning Android tool caches..."
        # Legacy AVD/build caches under ~/.android; regenerated on demand.
        Remove-SafelyWithTracking -Path "$env:USERPROFILE\.android\cache" -Description "Android cache"
        Remove-SafelyWithTracking -Path "$env:USERPROFILE\.android\build-cache" -Description "Android build-cache"
    }

    Write-Item "✓" "Green" "Cleaning Android Studio caches..."
    $androidStudioPaths = @(
        "$env:LOCALAPPDATA\Google\AndroidStudio*",
        "$env:LOCALAPPDATA\JetBrains\AndroidStudio*"
    )

    foreach ($pattern in $androidStudioPaths) {
        $paths = Get-ChildItem -Path (Split-Path $pattern -Parent) -Filter (Split-Path $pattern -Leaf) -Directory -ErrorAction SilentlyContinue
        foreach ($path in $paths) {
            Remove-SafelyWithTracking -Path $path.FullName -Description "Android Studio cache: $($path.Name)"
        }
    }
}

function Clear-AndroidSdk {
    $sdkPath = "$env:LOCALAPPDATA\Android\Sdk"

    if (Test-Path $sdkPath) {
        Write-Item "✓" "Green" "Cleaning old Android SDK build-tools (keeping latest 2 versions)..."

        $buildToolsPath = "$sdkPath\build-tools"
        if (Test-Path $buildToolsPath) {
            $versions = Get-ChildItem -Path $buildToolsPath -Directory | Sort-Object Name -Descending
            $toRemove = $versions | Select-Object -Skip 2

            foreach ($version in $toRemove) {
                Remove-SafelyWithTracking -Path $version.FullName -Description "Old build-tools: $($version.Name)"
            }
        }

        Write-Item "✓" "Green" "Cleaning SDK temp files..."
        Remove-SafelyWithTracking -Path "$sdkPath\.temp" -Description "SDK temp folder"
    } else {
        Write-Item "✕" "Yellow" "Android SDK not found. Skipping."
    }
}

function Clear-Flutter {
    param([string]$SearchDir = ".")

    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        Write-Item "✕" "Yellow" "Flutter command not found. Skipping."
        return
    }

    Write-Item "✓" "Green" "Cleaning Flutter projects recursively from: $SearchDir"

    if (-not (Test-Path $SearchDir)) {
        Write-Item "✕" "Red" "Directory not found: $SearchDir"
        return
    }

    $pubspecFiles = Get-ChildItem -Path $SearchDir -Filter "pubspec.yaml" -Recurse -ErrorAction SilentlyContinue
    $cleanedCount = 0

    foreach ($pubspec in $pubspecFiles) {
        $projectDir = $pubspec.DirectoryName
        Write-Host "  Cleaning: $projectDir" -ForegroundColor Cyan

        Push-Location $projectDir

        # FVM cleanup
        if (Test-Path ".fvm") {
            Write-Host "    Removing FVM cache..." -ForegroundColor DarkGray
            Remove-SafelyWithTracking -Path ".fvm" -Description "FVM folder"
        }
        if (Test-Path ".fvmrc") {
            Remove-SafelyWithTracking -Path ".fvmrc" -Description "FVM config"
        }

        # Flutter build artifacts
        Write-Host "    Removing Flutter build artifacts..." -ForegroundColor DarkGray
        Remove-SafelyWithTracking -Path "build" -Description "build folder"
        Remove-SafelyWithTracking -Path ".dart_tool" -Description ".dart_tool folder"
        Remove-SafelyWithTracking -Path ".packages" -Description ".packages file"
        Remove-SafelyWithTracking -Path "pubspec.lock" -Description "pubspec.lock file"

        # Android artifacts
        if (Test-Path "android") {
            Write-Host "    Removing Android build artifacts..." -ForegroundColor DarkGray
            Remove-SafelyWithTracking -Path "android\.gradle" -Description "Android Gradle cache"
            Remove-SafelyWithTracking -Path "android\build" -Description "Android build folder"
            Remove-SafelyWithTracking -Path "android\app\build" -Description "Android app build folder"
        }

        # Windows artifacts
        if (Test-Path "windows\flutter\ephemeral") {
            Write-Host "    Removing Windows ephemeral files..." -ForegroundColor DarkGray
            Remove-SafelyWithTracking -Path "windows\flutter\ephemeral" -Description "Windows ephemeral folder"
        }

        Pop-Location
        $cleanedCount++
        Write-Host "  ✅ Cleaned $projectDir" -ForegroundColor Green
    }

    if ($cleanedCount -gt 0) {
        Write-Item "✓" "Green" "Cleaned $cleanedCount Flutter project(s)"
    } else {
        Write-Item "ℹ️" "Yellow" "No Flutter projects found in: $SearchDir"
    }

    Write-Item "✓" "Green" "Cleaning Flutter global cache..."
    try {
        flutter cache clean 2>$null
    } catch {
        Write-Item "✕" "Yellow" "Could not clean Flutter global cache"
    }
}

function Clear-NpmYarnPnpm {
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        Write-Item "✓" "Green" "Cleaning npm cache..."
        try {
            npm cache clean --force 2>$null
        } catch {
            Write-Item "✕" "Yellow" "Could not clean npm cache"
        }
    } else {
        Write-Item "✕" "Yellow" "npm not found. Skipping."
    }

    if (Get-Command yarn -ErrorAction SilentlyContinue) {
        Write-Item "✓" "Green" "Cleaning yarn cache..."
        try {
            yarn cache clean 2>$null
        } catch {
            Write-Item "✕" "Yellow" "Could not clean yarn cache"
        }
    } else {
        Write-Item "✕" "Yellow" "yarn not found. Skipping."
    }

    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        Write-Item "✓" "Green" "Pruning pnpm store..."
        try {
            pnpm store prune 2>$null
        } catch {
            Write-Item "✕" "Yellow" "Could not prune pnpm store"
        }
    } else {
        Write-Item "✕" "Yellow" "pnpm not found. Skipping."
    }

    # Manual pnpm cache cleanup
    Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\pnpm\store" -Description "pnpm store"
    Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\pnpm-cache" -Description "pnpm cache"
}

function Clear-NuGet {
    Write-Item "✓" "Green" "Cleaning NuGet caches..."

    Remove-SafelyWithTracking -Path "$env:USERPROFILE\.nuget\packages" -Description "NuGet global packages"
    Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\NuGet\v3-cache" -Description "NuGet HTTP cache"
    Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\NuGet\plugins-cache" -Description "NuGet plugins cache"
    Remove-SafelyWithTracking -Path "$env:TEMP\NuGetScratch" -Description "NuGet temp files"

    # Alternative: Use dotnet CLI if available
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        try {
            dotnet nuget locals all --clear 2>$null
            Write-Item "✓" "Green" "Cleared NuGet caches via dotnet CLI"
        } catch {
            Write-Item "ℹ️" "Yellow" "dotnet nuget locals command skipped"
        }
    }
}

function Clear-PlatformIO {
    $pioBin = "$env:USERPROFILE\.platformio\penv\Scripts\pio.exe"

    if (-not (Test-Path $pioBin)) {
        if (Get-Command pio -ErrorAction SilentlyContinue) {
            $pioBin = "pio"
        } else {
            Write-Item "✕" "Yellow" "PlatformIO not found. Skipping."
            return
        }
    }

    Write-Item "✓" "Green" "Cleaning PlatformIO project builds..."

    $platformioFiles = Get-ChildItem -Path $env:USERPROFILE -Filter "platformio.ini" -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                       Where-Object { $_.FullName -notmatch "\\Library\\" }

    foreach ($file in $platformioFiles) {
        $projectDir = $file.DirectoryName
        Write-Host "  Running pio clean in: $projectDir" -ForegroundColor Cyan

        Push-Location $projectDir
        try {
            & $pioBin run -t clean 2>$null
        } catch {
            Write-Item "✕" "Yellow" "Could not clean $projectDir"
        }
        Pop-Location
    }
}

function Clear-IdeCaches {
    Write-Item "✓" "Green" "Cleaning JetBrains IDE caches..."

    $jetBrainsVersions = Get-ChildItem -Path "$env:LOCALAPPDATA\JetBrains" -Directory -ErrorAction SilentlyContinue
    foreach ($version in $jetBrainsVersions) {
        Remove-SafelyWithTracking -Path "$($version.FullName)\caches" -Description "JetBrains caches: $($version.Name)"
        Remove-SafelyWithTracking -Path "$($version.FullName)\index" -Description "JetBrains index: $($version.Name)"
        Remove-SafelyWithTracking -Path "$($version.FullName)\tmp" -Description "JetBrains temp: $($version.Name)"
    }

    Write-Item "✓" "Green" "Cleaning VSCode cache..."
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code\Cache" -Description "VSCode Cache"
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code\CachedData" -Description "VSCode CachedData"
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code\CachedExtensionVSIXs" -Description "VSCode CachedExtensionVSIXs"
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code\User\workspaceStorage" -Description "VSCode workspaceStorage"

    Write-Item "✓" "Green" "Cleaning VSCode Insiders cache..."
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code - Insiders\Cache" -Description "VSCode Insiders Cache"
    Remove-SafelyWithTracking -Path "$env:APPDATA\Code - Insiders\CachedData" -Description "VSCode Insiders CachedData"
}

function Clear-WindowsTemp {
    Write-Item "✓" "Green" "Cleaning user temp files..."

    Get-ChildItem -Path $env:TEMP -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-SafelyWithTracking -Path $_.FullName -Description "User temp: $($_.Name)"
    }

    Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\Temp" -Description "Local temp folder"

    Write-Item "✓" "Green" "Emptying Recycle Bin..."
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
        Write-Item "✓" "Green" "Recycle Bin emptied"
    } catch {
        Write-Item "✕" "Yellow" "Could not empty Recycle Bin"
    }

    if (Test-Administrator) {
        Write-Item "✓" "Green" "Cleaning system temp files (admin)..."

        Get-ChildItem -Path "C:\Windows\Temp" -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-SafelyWithTracking -Path $_.FullName -Description "System temp: $($_.Name)"
        }

        Write-Item "✓" "Green" "Cleaning Windows Update cache (optional)..."
        Get-ChildItem -Path "C:\Windows\SoftwareDistribution\Download" -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-SafelyWithTracking -Path $_.FullName -Description "Windows Update: $($_.Name)"
        }
    } else {
        Write-Item "ℹ️" "Yellow" "System temp cleanup requires admin privileges (skipped)"
    }
}

function Clear-BrowserCaches {
    $browsers = @{
        "Chrome" = @{
            "Cache" = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache"
            "CodeCache" = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache"
        }
        "Edge" = @{
            "Cache" = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache"
            "CodeCache" = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache"
        }
        "Brave" = @{
            "Cache" = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache"
            "CodeCache" = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Code Cache"
        }
        "Opera" = @{
            "Cache" = "$env:APPDATA\Opera Software\Opera Stable\Cache"
        }
        "Opera GX" = @{
            "Cache" = "$env:APPDATA\Opera Software\Opera GX Stable\Cache"
        }
    }

    foreach ($browser in $browsers.Keys) {
        $found = $false
        foreach ($cacheType in $browsers[$browser].Keys) {
            $path = $browsers[$browser][$cacheType]
            if (Test-Path $path) {
                $found = $true
                Remove-SafelyWithTracking -Path $path -Description "$browser $cacheType"
            }
        }
        if (-not $found) {
            Write-Item "✕" "Yellow" "$browser cache not found. Skipping."
        }
    }

    # Firefox (multiple profiles)
    $firefoxProfiles = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $firefoxProfiles) {
        Write-Item "✓" "Green" "Cleaning Firefox cache..."
        $profiles = Get-ChildItem -Path $firefoxProfiles -Directory -ErrorAction SilentlyContinue
        foreach ($profile in $profiles) {
            Remove-SafelyWithTracking -Path "$($profile.FullName)\cache2" -Description "Firefox cache: $($profile.Name)"
        }
    } else {
        Write-Item "✕" "Yellow" "Firefox cache not found. Skipping."
    }
}

function Clear-AppContainers {
    Write-Item "✓" "Green" "Cleaning app container caches..."

    # Slack
    if (Test-Path "$env:APPDATA\Slack") {
        Remove-SafelyWithTracking -Path "$env:APPDATA\Slack\Cache" -Description "Slack Cache"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Slack\Service Worker\CacheStorage" -Description "Slack Service Worker"
    }

    # Microsoft Teams Classic
    if (Test-Path "$env:APPDATA\Microsoft\Teams") {
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\Cache" -Description "Teams Cache"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\blob_storage" -Description "Teams blob storage"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\databases" -Description "Teams databases"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\GPUCache" -Description "Teams GPU Cache"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\IndexedDB" -Description "Teams IndexedDB"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\Local Storage" -Description "Teams Local Storage"
        Remove-SafelyWithTracking -Path "$env:APPDATA\Microsoft\Teams\tmp" -Description "Teams temp"
    }

    # Microsoft Teams New
    $teamsNew = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams"
    if (Test-Path $teamsNew) {
        Remove-SafelyWithTracking -Path $teamsNew -Description "Teams New cache"
    }

    # Discord
    if (Test-Path "$env:APPDATA\discord") {
        Remove-SafelyWithTracking -Path "$env:APPDATA\discord\Cache" -Description "Discord Cache"
        Remove-SafelyWithTracking -Path "$env:APPDATA\discord\Code Cache" -Description "Discord Code Cache"
    }

    # Spotify
    if (Test-Path "$env:LOCALAPPDATA\Spotify") {
        Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\Spotify\Storage" -Description "Spotify Storage"
    }
    if (Test-Path "$env:APPDATA\Spotify") {
        Remove-SafelyWithTracking -Path "$env:APPDATA\Spotify" -Description "Spotify Data"
    }

    # WhatsApp
    if (Test-Path "$env:LOCALAPPDATA\WhatsApp") {
        Remove-SafelyWithTracking -Path "$env:LOCALAPPDATA\WhatsApp\Cache" -Description "WhatsApp Cache"
    }

    # WhatsApp UWP
    $whatsappUwp = Get-ChildItem -Path "$env:LOCALAPPDATA\Packages" -Filter "*WhatsApp*" -Directory -ErrorAction SilentlyContinue
    foreach ($pkg in $whatsappUwp) {
        Remove-SafelyWithTracking -Path "$($pkg.FullName)\LocalCache" -Description "WhatsApp UWP cache"
    }
}

function Clear-Cordova {
    $cordovaPath = "$env:USERPROFILE\.cordova"

    if (Test-Path $cordovaPath) {
        Write-Item "✓" "Green" "Cleaning Cordova tmp files..."
        # Cordova leaves stale npm tarballs/extractions under lib\tmp*
        $tmpDirs = Get-ChildItem -Path "$cordovaPath\lib" -Filter "tmp*" -Force -ErrorAction SilentlyContinue
        foreach ($d in $tmpDirs) {
            Remove-SafelyWithTracking -Path $d.FullName -Description "Cordova tmp: $($d.Name)"
        }
    } else {
        Write-Item "✕" "Yellow" "Cordova not found. Skipping."
    }
}

function Clear-Electron {
    $electronPath = "$env:LOCALAPPDATA\electron"

    if (Test-Path $electronPath) {
        Write-Item "✓" "Green" "Cleaning Electron cache..."
        # Cached prebuilt binaries; wipe contents, keep the dir electron expects
        $items = Get-ChildItem -Path $electronPath -Force -ErrorAction SilentlyContinue
        foreach ($i in $items) {
            Remove-SafelyWithTracking -Path $i.FullName -Description "Electron cache: $($i.Name)"
        }
    } else {
        Write-Item "✕" "Yellow" "Electron not found. Skipping."
    }
}

# Claude Code's native installer keeps every version it has ever installed
# under versions\ and never removes the old ones (~190 MB per release). Unlike
# every other target in this script that is NOT a cache directory: one of those
# files is the binary the `claude` command actually runs.
# There is no symlink to resolve on Windows (.local\bin\claude.exe is a COPY of
# the version in use), so the active one is identified by size and then SHA256.
# Read-only. Shared by Clear-ClaudeCode and Invoke-EstimateAll so the estimate
# and the cleanup cannot drift apart.
# Status: 'missing' (not installed) | 'unknown' (custom launcher: skip the
# target entirely) | 'ok' (Files is authoritative, possibly empty).
function Get-ClaudeRemovableVersions {
    $versionsDir = "$env:USERPROFILE\.local\share\claude\versions"
    $launcher    = "$env:USERPROFILE\.local\bin\claude.exe"

    if (-not (Test-Path $versionsDir)) {
        return [PSCustomObject]@{ Status = 'missing'; ActiveName = $null; Files = @(); InUse = @() }
    }
    if (-not (Test-Path $launcher)) {
        return [PSCustomObject]@{ Status = 'unknown'; ActiveName = $null; Files = @(); InUse = @() }
    }

    $files = @(Get-ChildItem -Path $versionsDir -File -Force -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        return [PSCustomObject]@{ Status = 'ok'; ActiveName = $null; Files = @(); InUse = @() }
    }

    # Hash only the candidates of exactly the launcher's size: hashing 200 MB
    # binaries that cannot possibly match is pure I/O.
    $launcherItem = Get-Item -LiteralPath $launcher -Force -ErrorAction SilentlyContinue
    $active = $null
    if ($launcherItem) {
        $launcherHash = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if ($launcherHash) {
            foreach ($f in ($files | Where-Object { $_.Length -eq $launcherItem.Length })) {
                $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
                if ($h -eq $launcherHash) { $active = $f; break }
            }
        }
    }
    # No match means the launcher is not one of these binaries: the user
    # replaced it with their own, exactly like a non-symlink launcher on
    # macOS/Linux. The version in use cannot be identified, so skip.
    if (-not $active) {
        return [PSCustomObject]@{ Status = 'unknown'; ActiveName = $null; Files = @(); InUse = @() }
    }

    # Keep the newest file as well: an update can land in versions\ without
    # being copied into bin\, so the newest one may legitimately not be the
    # one currently running.
    $newest = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    # Binaries an older session is still running from. $_.Path throws Access
    # Denied for other users' processes, and an exception raised inside the
    # pipeline would abort it and silently skip every process after it, so the
    # guard sits inside the scriptblock, per element, never around the pipeline.
    $inUse = @(Get-Process -ErrorAction SilentlyContinue |
               Where-Object { try { $_.Path -like "$versionsDir\*" } catch { $false } } |
               ForEach-Object { try { $_.Path } catch { $null } })

    $removable = @($files | Where-Object {
        $_.FullName -ne $active.FullName -and
        $_.FullName -ne $newest.FullName -and
        $inUse -notcontains $_.FullName
    })

    return [PSCustomObject]@{ Status = 'ok'; ActiveName = $active.Name; Files = $removable; InUse = $inUse }
}

# Prunes %USERPROFILE%\.local\share\claude\versions, keeping the version in use,
# the newest one, and anything a running session still holds open.
# Never touches %USERPROFILE%\.claude\ or .claude.json: settings, MCP config
# and session history live there.
function Clear-ClaudeCode {
    $info = Get-ClaudeRemovableVersions

    if ($info.Status -eq 'missing') {
        Write-Item "✕" "Yellow" "Claude Code not found. Skipping."
        return
    }
    if ($info.Status -eq 'unknown') {
        Write-Item "✕" "Yellow" "Claude Code: the version in use cannot be identified (custom launcher). Skipping."
        return
    }
    if ($info.InUse.Count -gt 0) {
        Write-Item "→" "Cyan" "Claude Code: $($info.InUse.Count) version(s) still running; keeping them."
    }
    if ($info.Files.Count -eq 0) {
        Write-Item "✓" "Green" "Claude Code: nothing to prune."
        return
    }

    Write-Item "✓" "Green" "Removing old Claude Code versions (keeping $($info.ActiveName) and the newest one)..."
    foreach ($f in $info.Files) {
        Remove-SafelyWithTracking -Path $f.FullName -Description "Claude Code version: $($f.Name)"
    }
}

# -Interactive offers the deeper `prune -af` via a secondary prompt. "Clear All
# Caches" calls this without it, so a bulk run never deletes tagged images by
# surprise.
function Clear-Docker {
    param([switch]$Interactive)
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Item "✕" "Yellow" "Docker not found. Skipping."
        return
    }
    # `Get-Command` only proves the CLI exists; the daemon may still be down.
    $dfOut = docker system df 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $dfOut) {
        Write-Item "✕" "Yellow" "Docker daemon not running. Skipping."
        return
    }
    Write-Item "✓" "Green" "Docker disk usage:"
    $dfOut | ForEach-Object { Write-Host $_ }

    # `prune -f` removes stopped containers, unused networks, dangling
    # (untagged) images and unused build cache; -f skips docker's own
    # confirmation (the script already confirmed). `-a` additionally removes
    # EVERY image not used by a container, including tagged ones that may only
    # exist in a private registry — so it's opt-in via a prompt, never in the
    # bulk "Clear All" path. (--volumes stays omitted in both: it would delete
    # named-volume data like databases.)
    $pruneArgs = @('-f')
    if ($Interactive) {
        Write-Host ""
        Write-Host "Also remove unused but TAGGED images? Frees more space, but they" -ForegroundColor Yellow
        Write-Host "must be re-pulled/rebuilt (e.g. private-registry images). (y/N):" -ForegroundColor Yellow
        $ans = Read-Host
        if ($ans -eq 'y') { $pruneArgs = @('-af') }
    }
    docker system prune @pruneArgs
}

# --- Project roots, node_modules, Playwright ---

# Resolve the directories to scan into $script:ProjectRoots. Explicit dirs win
# over DEV_CLEANER_PROJECT_DIRS (split on ';' on Windows), which wins over the
# current directory. Missing dirs are dropped with a warning; a root nested in
# another root is dropped so nothing is scanned twice.
function Resolve-ProjectRoots {
    param([string[]]$Dirs)

    if ($Dirs) {
        $candidates = $Dirs
        $script:ProjectsDirSource = "command-line"
    } elseif ($env:DEV_CLEANER_PROJECT_DIRS) {
        $candidates = $env:DEV_CLEANER_PROJECT_DIRS -split [regex]::Escape([IO.Path]::PathSeparator)
        $script:ProjectsDirSource = "environment"
    } else {
        $candidates = @(".")
        $script:ProjectsDirSource = "default"
    }

    $valid = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $c = $c -replace '^~', $HOME
        if (Test-Path -LiteralPath $c -PathType Container) {
            $full = (Resolve-Path -LiteralPath $c).ProviderPath.TrimEnd('\', '/')
            if (-not $valid.Contains($full)) { $valid.Add($full) }
        } else {
            Write-Warning "Project directory not found, ignoring: $c"
        }
    }

    $sep = [IO.Path]::DirectorySeparatorChar
    $script:ProjectRoots = @($valid | Where-Object {
        $root = $_
        -not ($valid | Where-Object { $root.StartsWith($_ + $sep, [StringComparison]::OrdinalIgnoreCase) })
    })
}

# Every directory under the roots (roots included), never entering hidden
# folders, Library, *.app, AppData or links: they hold global installs and
# editor extensions, not projects. node_modules is returned but not entered.
function Get-ProjectTreeDirs {
    param([string[]]$Roots)
    $stack = [System.Collections.Generic.Stack[string]]::new()
    foreach ($r in $Roots) {
        $r
        $stack.Push($r)
    }
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            $n = $child.Name
            if ($n.StartsWith('.') -or $n -eq 'Library' -or $n -eq 'AppData' -or $n -like '*.app') { continue }
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $child.FullName
            if ($n -ne 'node_modules') { $stack.Push($child.FullName) }
        }
    }
}

# Top-level node_modules that sit next to a package.json.
function Get-NodeModulesDirs {
    param([string[]]$Roots)
    Get-ProjectTreeDirs -Roots $Roots | Where-Object {
        (Split-Path -Leaf $_) -eq 'node_modules' -and
        (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $_) 'package.json'))
    }
}

function Clear-NodeModules {
    param([string[]]$Roots = $script:ProjectRoots)

    if (-not $Roots) {
        Write-Item "✕" "Yellow" "No project directories to scan. Skipping."
        return
    }
    Write-Item "✓" "Green" "Removing node_modules under: $($Roots -join ', ')"
    $dirs = @(Get-NodeModulesDirs -Roots $Roots)
    if ($dirs.Count -eq 0) {
        Write-Item "ℹ️" "Yellow" "No node_modules found."
        return
    }
    foreach ($d in $dirs) {
        Remove-SafelyWithTracking -Path $d -Description "node_modules in $(Split-Path -Parent $d)"
    }
}

# Playwright's downloaded browsers; `npx playwright install` re-downloads them.
# PLAYWRIGHT_BROWSERS_PATH=0 keeps them inside node_modules (covered there).
function Get-PlaywrightCacheDir {
    if ($env:PLAYWRIGHT_BROWSERS_PATH) {
        if ($env:PLAYWRIGHT_BROWSERS_PATH -ne '0') { return $env:PLAYWRIGHT_BROWSERS_PATH }
        return $null
    }
    if (-not $env:LOCALAPPDATA) { return $null }
    return (Join-Path $env:LOCALAPPDATA 'ms-playwright')
}

function Clear-Playwright {
    $dir = Get-PlaywrightCacheDir
    if ($dir -and (Test-Path -LiteralPath $dir)) {
        Write-Item "✓" "Green" "Cleaning Playwright browsers..."
        # Wipe contents, keep the dir playwright expects
        foreach ($i in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            Remove-SafelyWithTracking -Path $i.FullName -Description "Playwright: $($i.Name)"
        }
    } else {
        Write-Item "✕" "Yellow" "Playwright browsers not found. Skipping."
    }
}

# --- Git worktrees with finished PRs ---

function Confirm-Action {
    param([string]$Prompt)
    $answer = Read-Host "$Prompt (y/N)"
    return ($answer -eq 'y' -or $answer -eq 'Y')
}

function Test-GhReady {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $false }
    gh auth status *> $null
    return ($LASTEXITCODE -eq 0)
}

# "owner/repo" for a GitHub remote URL, $null for any other host.
function ConvertTo-GitHubSlug {
    param([string]$Url)
    if ($Url -match '^(?:git@github\.com:|ssh://git@github\.com/|https://(?:[^@/]+@)?github\.com/)(.+?)(?:\.git)?/?$') {
        return $Matches[1]
    }
    return $null
}

# MERGED, CLOSED, OPEN, NONE (no PR) or UNKNOWN (gh failed, e.g. offline).
function Get-PrState {
    param([string]$Slug, [string]$Branch)
    $state = gh pr list --repo $Slug --head $Branch --state all --limit 1 --json state --jq '.[0].state // "NONE"' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $state) { return 'UNKNOWN' }
    return "$state".Trim()
}

function Get-WorktreeAction {
    param([string]$State, [bool]$Dirty)
    if ($Dirty) { return 'skip-dirty' }
    switch ($State) {
        'MERGED' { return 'remove' }
        'CLOSED' { return 'warn' }
        default  { return 'skip' }
    }
}

# Linked worktrees of every git repo under the roots (worktrees outside the
# roots included). The main worktree, detached HEADs, locked worktrees and
# prunable ones (directory already gone) are skipped.
function Get-Worktrees {
    param([string[]]$Roots)
    foreach ($repo in Get-ProjectTreeDirs -Roots $Roots) {
        if (-not (Test-Path -LiteralPath (Join-Path $repo '.git') -PathType Container)) { continue }
        $first = $true; $wt = $null; $branch = $null; $skip = $false
        # Records end with a blank line; the extra '' flushes the last one.
        foreach ($line in @(git -C $repo worktree list --porcelain 2>$null) + '') {
            if ($line.StartsWith('worktree ')) { $wt = $line.Substring(9) }
            elseif ($line.StartsWith('branch refs/heads/')) { $branch = $line.Substring(18) }
            elseif ($line -match '^(detached|locked|prunable)') { $skip = $true }
            elseif ($line -eq '') {
                if (-not $first -and -not $skip -and $wt -and $branch) {
                    [PSCustomObject]@{ Main = $repo; Path = $wt; Branch = $branch }
                }
                if ($wt) { $first = $false }
                $wt = $null; $branch = $null; $skip = $false
            }
        }
    }
}

# One row per worktree with its PR state and the action to take. Read-only.
function Get-WorktreeRows {
    param([string[]]$Roots)
    foreach ($w in Get-Worktrees -Roots $Roots) {
        $slug = ConvertTo-GitHubSlug (git -C $w.Main remote get-url origin 2>$null)
        $state = if ($slug) { Get-PrState $slug $w.Branch } else { 'UNKNOWN' }
        $dirty = [bool](git -C $w.Path status --porcelain 2>$null)
        [PSCustomObject]@{
            Action = Get-WorktreeAction $state $dirty
            State  = $state
            Slug   = $(if ($slug) { $slug } else { '-' })
            Main   = $w.Main
            Path   = $w.Path
            Branch = $w.Branch
        }
    }
}

# Remove one worktree and its local branch. A refused removal is only forced
# after a second, explicit yes; -Yes never forces. The branch is deleted with
# -d, so git keeps it if it is not merged locally (e.g. squash-merged PRs).
function Remove-Worktree {
    param($Row)
    git -C $Row.Main worktree remove $Row.Path 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        if ($script:AssumeYes) {
            Write-Item "✕" "Red" "Could not remove $($Row.Path) (not forced: -Yes never forces)."
            return $false
        }
        if (-not (Confirm-Action "Force removal of $($Row.Path)? Anything git still has there is lost.")) { return $false }
        git -C $Row.Main worktree remove --force $Row.Path 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { return $false }
    }
    Write-Item "✓" "Green" "Removed worktree: $($Row.Path)"

    git -C $Row.Main branch -d $Row.Branch *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Item "✓" "Green" "Deleted branch: $($Row.Branch)"
    } else {
        Write-Item "ℹ️" "Yellow" "Kept branch $($Row.Branch): not merged locally (squash merge?). Delete it with: git -C `"$($Row.Main)`" branch -D `"$($Row.Branch)`""
    }

    # Tidy a now-empty parent folder (e.g. worksets\<ticket>\); project roots stay.
    $parent = Split-Path -Parent $Row.Path
    if ($script:ProjectRoots -notcontains $parent -and (Test-Path -LiteralPath $parent) -and
        -not (Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $parent -Force -ErrorAction SilentlyContinue
    }
    return $true
}

# Offer to remove worktrees whose GitHub PR is merged (or closed, with a
# warning). Open, PR-less, non-GitHub and dirty worktrees are never offered.
function Clear-Worktrees {
    if (-not (Test-GhReady)) {
        Write-Item "✕" "Yellow" "GitHub CLI (gh) not found or not authenticated (run: gh auth login). Skipping."
        return
    }
    if (-not $script:ProjectRoots) {
        Write-Item "✕" "Yellow" "No project directories to scan. Skipping."
        return
    }

    Write-Item "✓" "Green" "Checking worktrees under: $($script:ProjectRoots -join ', ')"
    $rows = @(Get-WorktreeRows -Roots $script:ProjectRoots)
    if ($rows.Count -eq 0) {
        Write-Item "ℹ️" "Yellow" "No linked worktrees found."
        return
    }

    Write-Host ("  {0,-11} {1,-8} {2,-28} {3}" -f "ACTION", "PR", "REPO", "BRANCH → WORKTREE")
    foreach ($r in $rows) {
        Write-Host ("  {0,-11} {1,-8} {2,-28} {3} → {4}" -f $r.Action, $r.State, $r.Slug, $r.Branch, $r.Path)
    }
    Write-Host ""

    $removed = 0; $skipped = 0; $failed = 0
    foreach ($r in $rows) {
        if ($r.Action -eq 'remove') {
            $prompt = "Remove worktree $($r.Path) (branch $($r.Branch), PR merged)?"
        } elseif ($r.Action -eq 'warn') {
            $prompt = "The PR for $($r.Branch) was CLOSED without merging. Remove worktree $($r.Path) anyway?"
        } else {
            $skipped++
            continue
        }

        if ($script:DryRun) {
            Write-Item "•" "Yellow" "[DRY-RUN] Would remove worktree: $($r.Path) and branch $($r.Branch)"
            $removed++
            continue
        }
        # -Yes only covers merged PRs; a closed one always needs an explicit yes.
        $auto = ($r.Action -eq 'remove' -and $script:AssumeYes)
        if (-not $auto -and -not (Confirm-Action $prompt)) {
            $skipped++
            continue
        }
        if (Remove-Worktree $r) { $removed++ } else { $failed++ }
    }

    if ($script:DryRun) {
        Write-Item "✓" "Green" "Worktrees: $removed would be removed, $skipped skipped"
    } else {
        Write-Item "✓" "Green" "Worktrees: $removed removed, $skipped skipped, $failed failed"
    }
}

# --- Dispatch by stable key ---
# Same keys as the estimates, so -Only survives menu renumbering. ClearAllKeys
# is also the Clear All order; worktrees is never part of it.
$script:ClearAllKeys = @('visualstudio', 'android', 'androidsdk', 'flutter', 'npm', 'nuget', 'node_modules',
    'platformio', 'cordova', 'electron', 'playwright', 'claudecode', 'docker', 'ide', 'windowstemp',
    'browser', 'appcontainers')
$script:CleanupKeys = $script:ClearAllKeys + 'worktrees'
# Cleanups whose every deletion goes through Remove-SafelyWithTracking or
# checks $script:DryRun; the others call tools that delete for real.
$script:DryRunKeys = @('visualstudio', 'node_modules', 'playwright', 'worktrees')

function Invoke-Cleanup {
    param([string]$Key)
    switch ($Key) {
        "visualstudio" { Clear-VisualStudio -SearchDir $script:VsSearchDir }
        "android" { Clear-AndroidGradle }
        "androidsdk" { Clear-AndroidSdk }
        "flutter" { Clear-Flutter -SearchDir $script:FlutterSearchDir }
        "npm" { Clear-NpmYarnPnpm }
        "nuget" { Clear-NuGet }
        "node_modules" { Clear-NodeModules }
        "platformio" { Clear-PlatformIO }
        "cordova" { Clear-Cordova }
        "electron" { Clear-Electron }
        "playwright" { Clear-Playwright }
        "claudecode" { Clear-ClaudeCode }
        "docker" { Clear-Docker }
        "ide" { Clear-IdeCaches }
        "windowstemp" { Clear-WindowsTemp }
        "browser" { Clear-BrowserCaches }
        "appcontainers" { Clear-AppContainers }
        "worktrees" { Clear-Worktrees }
    }
}

# Option 1. node_modules only runs when project roots were set explicitly, so a
# bulk run started from the user folder cannot wipe every project's packages.
function Invoke-ClearAll {
    foreach ($key in $script:ClearAllKeys) {
        if ($key -eq 'node_modules' -and $script:ProjectsDirSource -eq 'default') {
            Write-Item "✕" "Yellow" "Skipping node_modules: no project directories set (use -ProjectsDir or DEV_CLEANER_PROJECT_DIRS)."
            continue
        }
        Invoke-Cleanup $key
    }
}

# -Only <key,...>: run the selected cleanups without the menu. Sets
# $script:OnlyExitCode (0 ok, 1 refused, 2 unknown key).
function Invoke-Only {
    param([string]$Keys)
    $script:OnlyExitCode = 0
    $list = @($Keys -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($k in $list) {
        if ($script:CleanupKeys -notcontains $k) {
            Write-Host "Error: Unknown cleanup: $k" -ForegroundColor Red
            Write-Host "Valid cleanups: $($script:CleanupKeys -join ', ')"
            $script:OnlyExitCode = 2
            return
        }
    }

    if ($script:DryRun) {
        $unsupported = @($list | Where-Object { $script:DryRunKeys -notcontains $_ })
        if ($unsupported) {
            Write-Host "-DryRun is only supported for: $($script:DryRunKeys -join ', ') (not: $($unsupported -join ', '))" -ForegroundColor Red
            $script:OnlyExitCode = 1
            return
        }
    } elseif (-not $script:AssumeYes) {
        if ([Console]::IsInputRedirected) {
            Write-Host "Refusing to delete without a terminal to confirm. Pass -Yes (or preview with -DryRun)." -ForegroundColor Red
            $script:OnlyExitCode = 1
            return
        }
        if (-not (Confirm-Action "Run $($list -join ', ')? Deleted files cannot be recovered.")) {
            Write-Host "Cancelled."
            return
        }
    }

    if ($list -contains 'windowstemp') { Request-Elevation }
    foreach ($k in $list) {
        Write-SectionHeader "Cleaning: $k"
        Invoke-Cleanup $k
    }
    Show-FailureSummary
}

# --- Reclaimable-space estimation ---
# Read-only: computes the current on-disk size of what each cleanup option
# would remove, then Show-Menu shows it next to each entry. Categories use
# stable string keys so the menu can be renumbered safely.
# IMPORTANT: keep these path lists in sync with the Clear-* functions above.

function Invoke-EstimateAll {
    Write-Item "🔍" "Cyan" "Calculating estimates... (this can take a while)"
    [int64]$total = 0
    [int64]$b = 0

    # Visual Studio - global caches only (~); project bin/obj/.vs not scanned
    Write-Host "  Measuring Visual Studio caches..." -ForegroundColor DarkGray
    $vsPaths = @()
    $vsVersions = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\VisualStudio" -Directory -ErrorAction SilentlyContinue
    foreach ($v in $vsVersions) {
        $vsPaths += "$($v.FullName)\ComponentModelCache"
        $vsPaths += "$($v.FullName)\MEFCacheData"
        $vsPaths += "$($v.FullName)\Designer\ShadowCache"
        $vsPaths += "$($v.FullName)\ImageLibrary"
    }
    $b = Get-PathSizeBytes $vsPaths
    Set-Estimate "visualstudio" ("~" + (Format-Size $b)); $total += $b

    # Android / Gradle
    Write-Host "  Measuring Android/Gradle caches..." -ForegroundColor DarkGray
    $b = Get-PathSizeBytes @(
        "$env:USERPROFILE\.gradle\caches",
        "$env:USERPROFILE\.gradle\daemon",
        "$env:USERPROFILE\.gradle\wrapper",
        "$env:USERPROFILE\.android\cache",
        "$env:USERPROFILE\.android\build-cache",
        "$env:LOCALAPPDATA\Google\AndroidStudio*",
        "$env:LOCALAPPDATA\JetBrains\AndroidStudio*"
    )
    Set-Estimate "android" (Format-Size $b); $total += $b

    # Android SDK - old build-tools (keep latest 2) + .temp
    Write-Host "  Measuring Android SDK..." -ForegroundColor DarkGray
    $sdkPath = "$env:LOCALAPPDATA\Android\Sdk"
    $sdkPaths = @("$sdkPath\.temp")
    $btPath = "$sdkPath\build-tools"
    if (Test-Path $btPath) {
        $old = Get-ChildItem -Path $btPath -Directory -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending | Select-Object -Skip 2
        foreach ($o in $old) { $sdkPaths += $o.FullName }
    }
    $b = Get-PathSizeBytes $sdkPaths
    Set-Estimate "androidsdk" (Format-Size $b); $total += $b

    # Flutter - global cache only (~)
    Write-Host "  Measuring Flutter global cache..." -ForegroundColor DarkGray
    $flPaths = @("$env:LOCALAPPDATA\Pub\Cache", "$env:APPDATA\Pub\Cache")
    $fcmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($fcmd) {
        $fbin = Split-Path $fcmd.Source -Parent
        if ($fbin) { $flPaths += (Join-Path $fbin "cache") }
    }
    $b = Get-PathSizeBytes $flPaths
    Set-Estimate "flutter" ("~" + (Format-Size $b)); $total += $b

    # npm / Yarn / pnpm (~)
    Write-Host "  Measuring npm/Yarn/pnpm caches..." -ForegroundColor DarkGray
    $npmPaths = @("$env:LOCALAPPDATA\pnpm\store", "$env:LOCALAPPDATA\pnpm-cache")
    if (Get-Command npm -ErrorAction SilentlyContinue) {
        $nc = (npm config get cache 2>$null | Select-Object -First 1)
        if ($nc) { $nc = "$nc".Trim() }
        if ($nc -and $nc -ne "undefined" -and $nc -ne "null") { $npmPaths += (Join-Path $nc "_cacache") }
    }
    if (Get-Command yarn -ErrorAction SilentlyContinue) {
        $yd = (yarn cache dir 2>$null | Select-Object -First 1)
        if ($yd) { $npmPaths += "$yd".Trim() }
    }
    if (Get-Command pnpm -ErrorAction SilentlyContinue) {
        $pd = (pnpm store path 2>$null | Select-Object -First 1)
        if ($pd) { $npmPaths += "$pd".Trim() }
    }
    $b = Get-PathSizeBytes $npmPaths
    Set-Estimate "npm" ("~" + (Format-Size $b)); $total += $b

    # NuGet
    Write-Host "  Measuring NuGet caches..." -ForegroundColor DarkGray
    $b = Get-PathSizeBytes @(
        "$env:USERPROFILE\.nuget\packages",
        "$env:LOCALAPPDATA\NuGet\v3-cache",
        "$env:LOCALAPPDATA\NuGet\plugins-cache",
        "$env:TEMP\NuGetScratch"
    )
    Set-Estimate "nuget" (Format-Size $b); $total += $b

    # PlatformIO - global cache only (~)
    Write-Host "  Measuring PlatformIO global cache..." -ForegroundColor DarkGray
    $b = Get-PathSizeBytes @("$env:USERPROFILE\.platformio\.cache")
    Set-Estimate "platformio" ("~" + (Format-Size $b)); $total += $b

    # IDE caches (JetBrains + VSCode)
    Write-Host "  Measuring IDE caches..." -ForegroundColor DarkGray
    $idePaths = @(
        "$env:APPDATA\Code\Cache",
        "$env:APPDATA\Code\CachedData",
        "$env:APPDATA\Code\User\workspaceStorage",
        "$env:APPDATA\Code - Insiders\Cache",
        "$env:APPDATA\Code - Insiders\CachedData"
    )
    $jb = Get-ChildItem -Path "$env:LOCALAPPDATA\JetBrains" -Directory -ErrorAction SilentlyContinue
    foreach ($j in $jb) {
        $idePaths += "$($j.FullName)\caches"
        $idePaths += "$($j.FullName)\index"
        $idePaths += "$($j.FullName)\tmp"
    }
    $b = Get-PathSizeBytes $idePaths
    Set-Estimate "ide" (Format-Size $b); $total += $b

    # Windows Temp (~) - Recycle Bin / admin system temp not measured
    Write-Host "  Measuring Windows temp..." -ForegroundColor DarkGray
    $b = Get-PathSizeBytes @("$env:TEMP", "$env:LOCALAPPDATA\Temp")
    Set-Estimate "windowstemp" ("~" + (Format-Size $b)); $total += $b

    # Browser caches
    Write-Host "  Measuring browser caches..." -ForegroundColor DarkGray
    $brPaths = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Code Cache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Cache",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data\Default\Code Cache",
        "$env:APPDATA\Opera Software\Opera Stable\Cache",
        "$env:APPDATA\Opera Software\Opera GX Stable\Cache"
    )
    $ffProfiles = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $ffProfiles) {
        $profs = Get-ChildItem -Path $ffProfiles -Directory -ErrorAction SilentlyContinue
        foreach ($p in $profs) { $brPaths += "$($p.FullName)\cache2" }
    }
    $b = Get-PathSizeBytes $brPaths
    Set-Estimate "browser" (Format-Size $b); $total += $b

    # Cordova tmp files
    Write-Host "  Measuring Cordova tmp files..." -ForegroundColor DarkGray
    $cordovaTmp = @()
    $cordovaDirs = Get-ChildItem -Path "$env:USERPROFILE\.cordova\lib" -Filter "tmp*" -Force -ErrorAction SilentlyContinue
    foreach ($t in $cordovaDirs) { $cordovaTmp += $t.FullName }
    $b = Get-PathSizeBytes $cordovaTmp
    Set-Estimate "cordova" (Format-Size $b); $total += $b

    # Electron cache
    Write-Host "  Measuring Electron cache..." -ForegroundColor DarkGray
    $electronCache = @()
    $electronItems = Get-ChildItem -Path "$env:LOCALAPPDATA\electron" -Force -ErrorAction SilentlyContinue
    foreach ($e in $electronItems) { $electronCache += $e.FullName }
    $b = Get-PathSizeBytes $electronCache
    Set-Estimate "electron" (Format-Size $b); $total += $b

    # Claude Code old versions
    Write-Host "  Measuring Claude Code old versions..." -ForegroundColor DarkGray
    $claudeInfo = Get-ClaudeRemovableVersions
    if ($claudeInfo.Status -eq 'unknown') {
        # Not measurable, so not added to the byte total, like the Docker
        # "daemon not running" case below.
        Set-Estimate "claudecode" "n/a (custom launcher)"
    } else {
        $claudePaths = @()
        foreach ($f in $claudeInfo.Files) { $claudePaths += $f.FullName }
        $b = Get-PathSizeBytes $claudePaths
        Set-Estimate "claudecode" (Format-Size $b); $total += $b
    }

    # Docker is not path-based: ask docker itself (read-only). Two figures,
    # because option 11 offers two prune modes:
    #   -f  : build-cache reclaimable + dangling (untagged) images
    #   -af : the above + ALL images not used by a container (tagged too)
    # Build-cache reclaimable comes from the `system df` summary (Docker
    # computes it correctly; only its Images figure is unreliable with the
    # containerd image store). Per-image sizes come from `system df -v`,
    # summing UNIQUE SIZE of 0-container rows so shared layers aren't double
    # counted. Approximate, so not added to the byte total.
    Write-Host "  Measuring Docker reclaimable space..." -ForegroundColor DarkGray
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $dfFmt = docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $dfFmt) {
            $cacheTok = (($dfFmt | Where-Object { $_ -like 'Build Cache|*' }) -split '\|', 2)[1] -replace ' *\(.*', ''
            [int64]$cacheBytes = Convert-DockerSize $cacheTok
            # Parse the "Images space usage:" table. CREATED is multi-word
            # ("4 days ago"), so index columns from the RIGHT: last = CONTAINERS,
            # second-to-last = UNIQUE SIZE. Dangling images have REPOSITORY <none>.
            [int64]$danglingBytes = 0
            [int64]$allUnusedBytes = 0
            $inImages = $false
            foreach ($line in (docker system df -v 2>$null)) {
                if ($line -match '^Images space usage:') { $inImages = $true; continue }
                if (-not $inImages) { continue }
                if ($line -match '^REPOSITORY') { continue }
                if ([string]::IsNullOrWhiteSpace($line)) { $inImages = $false; continue }
                $cols = $line.Trim() -split '\s+'
                if ($cols.Count -lt 3 -or $cols[-1] -ne '0') { continue }
                $uniq = Convert-DockerSize $cols[-2]
                $allUnusedBytes += $uniq
                if ($cols[0] -eq '<none>') { $danglingBytes += $uniq }
            }
            [int64]$fBytes = $cacheBytes + $danglingBytes
            [int64]$afBytes = $cacheBytes + $allUnusedBytes
            if ($afBytes -gt $fBytes) {
                Set-Estimate "docker" "~$(Format-Size $fBytes) → ~$(Format-Size $afBytes) with -a"
            } else {
                Set-Estimate "docker" "~$(Format-Size $fBytes)"
            }
        } else {
            Set-Estimate "docker" "n/a (daemon not running)"
        }
    } else {
        Set-Estimate "docker" "n/a (docker not found)"
    }

    # App containers
    Write-Host "  Measuring app caches..." -ForegroundColor DarkGray
    $acPaths = @(
        "$env:APPDATA\Slack\Cache",
        "$env:APPDATA\Slack\Service Worker\CacheStorage",
        "$env:APPDATA\Microsoft\Teams\Cache",
        "$env:APPDATA\Microsoft\Teams\blob_storage",
        "$env:APPDATA\Microsoft\Teams\databases",
        "$env:APPDATA\Microsoft\Teams\GPUCache",
        "$env:APPDATA\Microsoft\Teams\IndexedDB",
        "$env:APPDATA\Microsoft\Teams\Local Storage",
        "$env:APPDATA\Microsoft\Teams\tmp",
        "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams",
        "$env:APPDATA\discord\Cache",
        "$env:APPDATA\discord\Code Cache",
        "$env:LOCALAPPDATA\Spotify\Storage",
        "$env:APPDATA\Spotify",
        "$env:LOCALAPPDATA\WhatsApp\Cache"
    )
    $waUwp = Get-ChildItem -Path "$env:LOCALAPPDATA\Packages" -Filter "*WhatsApp*" -Directory -ErrorAction SilentlyContinue
    foreach ($w in $waUwp) { $acPaths += "$($w.FullName)\LocalCache" }
    $b = Get-PathSizeBytes $acPaths
    Set-Estimate "appcontainers" (Format-Size $b); $total += $b

    Write-Host "  Measuring Playwright browsers..." -ForegroundColor DarkGray
    $pw = Get-PlaywrightCacheDir
    $b = if ($pw) { Get-PathSizeBytes @($pw) } else { [int64]0 }
    Set-Estimate "playwright" (Format-Size $b); $total += $b

    # Counted toward the Clear All total only when Clear All would clean it
    # (explicit project roots, see Invoke-ClearAll).
    Write-Host "  Measuring project node_modules..." -ForegroundColor DarkGray
    $nm = @(Get-NodeModulesDirs -Roots $script:ProjectRoots)
    $b = if ($nm) { Get-PathSizeBytes $nm } else { [int64]0 }
    Set-Estimate "node_modules" (Format-Size $b)
    if ($script:ProjectsDirSource -ne 'default') { $total += $b }

    # Counted, not measured: deciding needs a gh call per worktree.
    Write-Host "  Checking worktree PRs..." -ForegroundColor DarkGray
    if (Test-GhReady) {
        $n = @(Get-WorktreeRows -Roots $script:ProjectRoots | Where-Object { $_.Action -in 'remove', 'warn' }).Count
        Set-Estimate "worktrees" "~$n candidate(s)"
    } else {
        Set-Estimate "worktrees" "n/a (gh not available)"
    }

    Set-Estimate "total" ("~" + (Format-Size $total))
    $script:EstimatesReady = $true
    Write-Item "✓" "Green" "Estimates ready. ~ marks approximate values."
}

# --- Menu Display ---

function Show-Menu {
    Clear-Host
    $currentFreeSpace = Get-DiskSpace

    Show-Logo
    Write-Host "  Version: v$SCRIPT_VERSION" -ForegroundColor DarkGray
    Write-Item "✨" "Green" "Free Space: $currentFreeSpace"
    Write-Host ""
    Write-SectionHeader "Available Options:"
    Write-Host " 0. Exit Program" -ForegroundColor Red
    Write-Host (" 1. Clear All Caches" + (Get-Est 'total')) -ForegroundColor Green
    Write-Host "─── Development Tools ───" -ForegroundColor DarkGray
    Write-Host (" 2. Clear Visual Studio Caches (bin/obj/.vs + global)" + (Get-Est 'visualstudio')) -ForegroundColor Green
    Write-Host (" 3. Clear Android/Gradle Caches" + (Get-Est 'android')) -ForegroundColor Green
    Write-Host (" 4. Clear Android SDK (old build-tools)" + (Get-Est 'androidsdk')) -ForegroundColor Green
    Write-Host " 5. Clear Flutter Caches " -NoNewline -ForegroundColor Green
    Write-Host ("(with custom directory option)" + (Get-Est 'flutter')) -ForegroundColor DarkGray
    Write-Host (" 6. Clear npm/Yarn/pnpm Caches" + (Get-Est 'npm')) -ForegroundColor Green
    Write-Host (" 7. Clear NuGet Package Cache" + (Get-Est 'nuget')) -ForegroundColor Green
    Write-Host (" 8. Clear PlatformIO Caches" + (Get-Est 'platformio')) -ForegroundColor Green
    Write-Host (" 9. Clear Cordova tmp files" + (Get-Est 'cordova')) -ForegroundColor Green
    Write-Host ("10. Clear Electron cache" + (Get-Est 'electron')) -ForegroundColor Green
    Write-Host ("11. Clear Docker (prune containers, dangling images & build cache; asks before removing unused tagged images)" + (Get-Est 'docker')) -ForegroundColor Green
    Write-Host "─── AI CLI Tools ───" -ForegroundColor DarkGray
    Write-Host ("12. Clear old Claude Code versions (keeps the version in use)" + (Get-Est 'claudecode')) -ForegroundColor Green
    Write-Host "─── IDEs & Editors ───" -ForegroundColor DarkGray
    Write-Host ("13. Clear IDE Caches (JetBrains, VSCode)" + (Get-Est 'ide')) -ForegroundColor Green
    Write-Host "─── System ───" -ForegroundColor DarkGray
    Write-Host ("14. Clean Windows Temp & Recycle Bin" + (Get-Est 'windowstemp')) -ForegroundColor Green
    Write-Host ("15. Clear Browser Caches (Chrome, Edge, Firefox, Brave, Opera)" + (Get-Est 'browser')) -ForegroundColor Green
    Write-Host ("16. Clean App Caches (Slack, Teams, Discord, Spotify, WhatsApp)" + (Get-Est 'appcontainers')) -ForegroundColor Green
    Write-Host "─── Projects ───" -ForegroundColor DarkGray
    Write-Host ("17. Clear project node_modules (under project directories)" + (Get-Est 'node_modules')) -ForegroundColor Green
    Write-Host ("18. Clear Playwright browsers" + (Get-Est 'playwright')) -ForegroundColor Green
    Write-Host ("19. Remove git worktrees with merged PRs (asks per worktree; needs gh)" + (Get-Est 'worktrees')) -ForegroundColor Green
    Write-Host ""
    Write-Host "99. Estimate reclaimable space (read-only, ~ = approximate)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "→ Please enter your choice (0-19, or 99 to estimate): " -NoNewline
}

# --- Main Loop ---

function Start-MainLoop {
    while ($true) {
        Show-Menu
        $choice = Read-Host

        Write-Host ""
        $initialFreeSpace = Get-DiskSpace

        switch ($choice) {
            "0" {
                Write-Host "Exiting cleanup utility. Goodbye!" -ForegroundColor Green
                return
            }
            "1" {
                Write-SectionHeader "Performing ALL Cleanup Tasks"
                Invoke-ClearAll
            }
            "2" {
                Write-SectionHeader "Performing Visual Studio Cleanup"
                Write-Host "Current Visual Studio search directory: $script:VsSearchDir" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "Enter a custom directory path, or press Enter to use current setting:" -ForegroundColor Yellow
                $customVsDir = Read-Host

                if ($customVsDir -and (Test-Path $customVsDir)) {
                    Write-Host "Using interactive override: $customVsDir" -ForegroundColor Cyan
                    Clear-VisualStudio -SearchDir $customVsDir
                } elseif ($customVsDir) {
                    Write-Host "Directory does not exist: $customVsDir" -ForegroundColor Red
                    Write-Host "Falling back to: $script:VsSearchDir" -ForegroundColor Yellow
                    Clear-VisualStudio -SearchDir $script:VsSearchDir
                } else {
                    Clear-VisualStudio -SearchDir $script:VsSearchDir
                }
            }
            "3" {
                Write-SectionHeader "Performing Android/Gradle Cleanup"
                Clear-AndroidGradle
            }
            "4" {
                Write-SectionHeader "Performing Android SDK Cleanup"
                Clear-AndroidSdk
            }
            "5" {
                Write-SectionHeader "Performing Flutter Cleanup"
                Write-Host "Current Flutter search directory: $script:FlutterSearchDir" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "Enter a custom directory path, or press Enter to use current setting:" -ForegroundColor Yellow
                $customFlutterDir = Read-Host

                if ($customFlutterDir -and (Test-Path $customFlutterDir)) {
                    Write-Host "Using interactive override: $customFlutterDir" -ForegroundColor Cyan
                    Clear-Flutter -SearchDir $customFlutterDir
                } elseif ($customFlutterDir) {
                    Write-Host "Directory does not exist: $customFlutterDir" -ForegroundColor Red
                    Write-Host "Falling back to: $script:FlutterSearchDir" -ForegroundColor Yellow
                    Clear-Flutter -SearchDir $script:FlutterSearchDir
                } else {
                    Clear-Flutter -SearchDir $script:FlutterSearchDir
                }
            }
            "6" {
                Write-SectionHeader "Performing npm/Yarn/pnpm Cleanup"
                Clear-NpmYarnPnpm
            }
            "7" {
                Write-SectionHeader "Performing NuGet Cache Cleanup"
                Clear-NuGet
            }
            "8" {
                Write-SectionHeader "Performing PlatformIO Cleanup"
                Clear-PlatformIO
            }
            "9" {
                Write-SectionHeader "Performing Cordova Cleanup"
                Clear-Cordova
            }
            "10" {
                Write-SectionHeader "Performing Electron Cleanup"
                Clear-Electron
            }
            "11" {
                Write-SectionHeader "Performing Docker Cleanup"
                Clear-Docker -Interactive
            }
            "12" {
                Write-SectionHeader "Performing Claude Code Version Cleanup"
                Clear-ClaudeCode
            }
            "13" {
                Write-SectionHeader "Performing IDE Caches Cleanup"
                Clear-IdeCaches
            }
            "14" {
                Write-SectionHeader "Performing Windows Temp & Recycle Bin Cleanup"
                Clear-WindowsTemp
            }
            "15" {
                Write-SectionHeader "Performing Browser Caches Cleanup"
                Clear-BrowserCaches
            }
            "16" {
                Write-SectionHeader "Performing App Caches Cleanup"
                Clear-AppContainers
            }
            "17" {
                Write-SectionHeader "Performing node_modules Cleanup"
                Clear-NodeModules
            }
            "18" {
                Write-SectionHeader "Performing Playwright Cleanup"
                Clear-Playwright
            }
            "19" {
                Write-SectionHeader "Performing Worktree Cleanup"
                Clear-Worktrees
            }
            "99" {
                Write-SectionHeader "Estimating Reclaimable Space"
                Invoke-EstimateAll
                # Read-only: skip the before/after summary and redraw the menu
                # with the freshly computed estimates.
                continue
            }
            default {
                Write-Host "Invalid choice. Please enter a number between 0 and 19." -ForegroundColor Red
                Start-Sleep -Seconds 2
                continue
            }
        }

        Show-FailureSummary

        $finalFreeSpace = Get-DiskSpace
        Write-Host ""
        Write-Host "✅ Cleanup task(s) completed!" -ForegroundColor Green
        Write-Host "Disk space before: $initialFreeSpace" -ForegroundColor Blue
        Write-Host "Disk space after:  $finalFreeSpace" -ForegroundColor Blue
        Write-Host ""
        Write-Host "Press Enter to return to the menu..." -NoNewline
        Read-Host
    }
}

# Dot-sourced (e.g. by the Pester suite): define the functions above, run nothing.
if ($MyInvocation.InvocationName -eq '.') { return }

# --- Entry Point ---

# Handle -Help flag
if ($Help) {
    Write-Host @"
Dev Cleanup Utility v$SCRIPT_VERSION
A powerful cleanup utility for development environments on Windows

Usage: .\dev-cleaner.ps1 [OPTIONS]

Options:
  -Help               Show this help message
  -Version            Show version information
  -FlutterDir PATH    Set custom directory for Flutter cleanup (default: current directory)
                      Example: .\dev-cleaner.ps1 -FlutterDir "C:\Projects"
  -VsDir PATH         Set custom directory for Visual Studio cleanup (default: current directory)
                      Example: .\dev-cleaner.ps1 -VsDir "C:\Projects\DotNet"
  -ProjectsDir PATHS  Directories to scan for node_modules and git worktrees
                      (comma-separated; default: current directory)
  -Only KEYS          Run only these cleanups (comma-separated), without the menu
  -Yes                Don't ask: confirm -Only and remove worktrees whose PR is merged
                      (closed PRs still ask; failed removals are never forced)
  -DryRun             Show what would be deleted (with -Only; supported for:
                      visualstudio, node_modules, playwright, worktrees)

Cleanup keys for -Only:
  $($script:CleanupKeys -join ', ')

Project cleanups:
  node_modules  node_modules next to a package.json
  worktrees     git worktrees whose GitHub PR is merged (or closed, with a warning);
                needs an authenticated gh. Never part of "Clear All", and worktrees
                with uncommitted changes are never offered.
  Scans skip hidden folders, AppData, Library and links. "Clear All" only cleans
  node_modules when project directories were set explicitly.

Interactive menu:
  Option 99 estimates the reclaimable space for every entry and redraws the
  menu with "(Estimate: <size>)". It is read-only (deletes nothing). A leading
  "~" marks an approximate value; Flutter, PlatformIO and Visual Studio
  estimates cover the global cache only.

Examples:
  .\dev-cleaner.ps1                                    # Run interactive menu
  .\dev-cleaner.ps1 -FlutterDir "C:\Dev\Flutter"       # Custom Flutter search directory
  .\dev-cleaner.ps1 -VsDir "C:\Dev\DotNet"             # Custom VS search directory
  .\dev-cleaner.ps1 -FlutterDir "D:\Projects" -VsDir "D:\VS"  # Both custom directories
  .\dev-cleaner.ps1 -Only node_modules,worktrees -ProjectsDir "C:\repos" -DryRun
  .\dev-cleaner.ps1 -Only npm,nuget,playwright -Yes     # Unattended

Environment Variables:
  `$env:FLUTTER_SEARCH_DIR = "C:\Projects\Flutter"
  `$env:VS_SEARCH_DIR = "C:\Projects\DotNet"
  `$env:DEV_CLEANER_PROJECT_DIRS = "C:\repos;D:\work"

Repository: $GITHUB_REPO
"@
    exit 0
}

# Handle -Version flag
if ($Version) {
    Write-Host "Dev Cleaner v$SCRIPT_VERSION"
    Write-Host "A powerful cleanup utility for development environments"
    Write-Host "Repository: $GITHUB_REPO"
    exit 0
}

# Determine Flutter search directory (priority: CLI > ENV > Default)
$script:FlutterSearchDir = "."
$script:FlutterDirSource = "default"

if ($env:FLUTTER_SEARCH_DIR) {
    $script:FlutterSearchDir = $env:FLUTTER_SEARCH_DIR
    $script:FlutterDirSource = "environment"
}

if ($FlutterDir) {
    $script:FlutterSearchDir = $FlutterDir
    $script:FlutterDirSource = "command-line"
}

# Validate Flutter directory
if ($script:FlutterSearchDir -ne "." -and -not (Test-Path $script:FlutterSearchDir)) {
    Write-Host "Warning: Flutter search directory does not exist: $script:FlutterSearchDir" -ForegroundColor Yellow
    Write-Host "Falling back to current directory." -ForegroundColor Yellow
    $script:FlutterSearchDir = "."
    $script:FlutterDirSource = "default"
}

# Determine Visual Studio search directory (priority: CLI > ENV > Default)
$script:VsSearchDir = "."
$script:VsDirSource = "default"

if ($env:VS_SEARCH_DIR) {
    $script:VsSearchDir = $env:VS_SEARCH_DIR
    $script:VsDirSource = "environment"
}

if ($VsDir) {
    $script:VsSearchDir = $VsDir
    $script:VsDirSource = "command-line"
}

# Validate VS directory
if ($script:VsSearchDir -ne "." -and -not (Test-Path $script:VsSearchDir)) {
    Write-Host "Warning: Visual Studio search directory does not exist: $script:VsSearchDir" -ForegroundColor Yellow
    Write-Host "Falling back to current directory." -ForegroundColor Yellow
    $script:VsSearchDir = "."
    $script:VsDirSource = "default"
}

# Determine project directories (priority: CLI > ENV > Default)
foreach ($d in $ProjectsDir) {
    if (-not (Test-Path -LiteralPath $d -PathType Container)) {
        Write-Host "Error: Project directory does not exist: $d" -ForegroundColor Red
        exit 1
    }
}
Resolve-ProjectRoots -Dirs $ProjectsDir

if ($Only) {
    Invoke-Only $Only
    exit $script:OnlyExitCode
}
if ($DryRun) {
    Write-Host "-DryRun needs -Only (supported: $($script:DryRunKeys -join ', '))." -ForegroundColor Red
    exit 1
}

# Request elevation
Request-Elevation

# Initial confirmation
Clear-Host
Write-Host "--- Dev Cleanup Utility ---" -ForegroundColor Red
Write-Host "This script will permanently delete cache files from your system."
Write-Host "Review the options carefully before proceeding."
Write-Host ""

# Report search directories
if ($script:FlutterSearchDir -ne ".") {
    Write-Host "Flutter search directory: $script:FlutterSearchDir" -ForegroundColor Cyan
    switch ($script:FlutterDirSource) {
        "environment" { Write-Host "  (set via FLUTTER_SEARCH_DIR environment variable)" -ForegroundColor DarkGray }
        "command-line" { Write-Host "  (set via -FlutterDir command-line argument)" -ForegroundColor DarkGray }
    }
    Write-Host ""
} else {
    Write-Host "Flutter search directory: current directory (default)" -ForegroundColor DarkGray
    Write-Host ""
}

if ($script:VsSearchDir -ne ".") {
    Write-Host "Visual Studio search directory: $script:VsSearchDir" -ForegroundColor Cyan
    switch ($script:VsDirSource) {
        "environment" { Write-Host "  (set via VS_SEARCH_DIR environment variable)" -ForegroundColor DarkGray }
        "command-line" { Write-Host "  (set via -VsDir command-line argument)" -ForegroundColor DarkGray }
    }
    Write-Host ""
} else {
    Write-Host "Visual Studio search directory: current directory (default)" -ForegroundColor DarkGray
    Write-Host ""
}

if ($script:ProjectsDirSource -ne "default") {
    Write-Host "Project directories: $($script:ProjectRoots -join ', ')" -ForegroundColor Cyan
    Write-Host ""
} else {
    Write-Host "Project directories: current directory (default)" -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host "⚠️ This action is IRREVERSIBLE for deleted files. ⚠️" -ForegroundColor Yellow
Write-Host "Please CLOSE all development applications (Visual Studio, Android Studio, VSCode, etc.) before running." -ForegroundColor Yellow
Write-Host ""
$initialConfirm = Read-Host "Are you sure you want to start the cleanup utility? (y/N)"

if ($initialConfirm -ne "y" -and $initialConfirm -ne "Y") {
    Write-Host "Cleanup utility cancelled."
    exit 0
}

# Start main loop
Start-MainLoop
