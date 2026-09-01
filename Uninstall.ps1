[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$InstallDirectory = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\CodexUsageOverlay'),
    [string]$LegacyInstallDirectory = '',
    [switch]$KeepConfig
)

$ErrorActionPreference = 'Stop'
$taskName = 'Codex Usage Overlay'
$targetDirectory = [IO.Path]::GetFullPath($InstallDirectory)
$targetRoot = [IO.Path]::GetPathRoot($targetDirectory).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($targetDirectory) -or $targetDirectory.TrimEnd('\') -eq $targetRoot) {
    throw 'Refusing to uninstall from an empty path or drive root.'
}

$legacyDirectory = $null
if (-not [string]::IsNullOrWhiteSpace($LegacyInstallDirectory)) {
    $legacyDirectory = [IO.Path]::GetFullPath($LegacyInstallDirectory)
} elseif (-not $PSBoundParameters.ContainsKey('InstallDirectory')) {
    $legacyDirectory = Join-Path ([IO.Path]::GetPathRoot($env:SystemRoot)) 'Tools\CodexUsageOverlay'
}
$ownedDirectories = @($targetDirectory)
if ($legacyDirectory -and -not $legacyDirectory.Equals($targetDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    $ownedDirectories += $legacyDirectory
}
$ownedDirectories = @($ownedDirectories | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Select-Object -Unique)
$foundOverlayArtifact = $false

function Test-OwnedCommandLine {
    param(
        [string]$CommandLine,
        [string]$ScriptPattern
    )
    if ($CommandLine -notmatch $ScriptPattern) { return $false }
    return @($ownedDirectories | Where-Object {
        $CommandLine.IndexOf(($_ + '\'), [StringComparison]::OrdinalIgnoreCase) -ge 0
    }).Count -gt 0
}

function Remove-OwnedShortcut {
    param(
        [string]$ShortcutPath,
        [string]$ExpectedLauncher
    )

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) { return $false }
    $shell = New-Object -ComObject 'WScript.Shell'
    $shortcut = $null
    try {
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        if ([string]$shortcut.Arguments -like ('*' + $ExpectedLauncher + '*')) {
            if ($PSCmdlet.ShouldProcess($ShortcutPath, 'Remove overlay shortcut')) {
                Remove-Item -LiteralPath $ShortcutPath -Force
            }
            return $true
        }
        return $false
    } finally {
        foreach ($item in @($shortcut, $shell)) {
            if ($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) | Out-Null
            }
        }
    }
}

# Stop and unregister the watcher before terminating processes. Otherwise the
# watcher can recreate the old overlay during the uninstall race window.
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    $taskOwned = @($task.Actions | Where-Object {
        Test-OwnedCommandLine -CommandLine ([string]$_.Arguments) -ScriptPattern '(?i)CodexOverlayWatcher\.ps1'
    }).Count -gt 0
    if ($taskOwned) {
        $foundOverlayArtifact = $true
        if ($PSCmdlet.ShouldProcess($taskName, 'Remove current-user scheduled task')) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
    }
}

for ($attempt = 0; $attempt -lt 3; $attempt++) {
    $ownedProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        Test-OwnedCommandLine -CommandLine ([string]$_.CommandLine) -ScriptPattern '(?i)(?:CodexUsageOverlay|CodexOverlayWatcher)\.ps1'
    })
    if ($ownedProcesses.Count -eq 0) { break }
    $foundOverlayArtifact = $true
    foreach ($process in $ownedProcesses) {
        if ($PSCmdlet.ShouldProcess("process $($process.ProcessId)", 'Stop overlay process')) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    if ($WhatIfPreference) { break }
    Start-Sleep -Milliseconds 150
}

$desktopShortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)) 'Codex Usage Overlay.lnk'
$startMenuShortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) 'Codex Usage Overlay.lnk'
$startupShortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) 'Codex Usage Overlay.lnk'
foreach ($directory in $ownedDirectories) {
    $launcherPath = Join-Path $directory 'Start-CodexUsageOverlay.vbs'
    if (Remove-OwnedShortcut -ShortcutPath $desktopShortcut -ExpectedLauncher $launcherPath) { $foundOverlayArtifact = $true }
    if (Remove-OwnedShortcut -ShortcutPath $startMenuShortcut -ExpectedLauncher $launcherPath) { $foundOverlayArtifact = $true }
    if (Remove-OwnedShortcut -ShortcutPath $startupShortcut -ExpectedLauncher $launcherPath) { $foundOverlayArtifact = $true }
}

$fixedKnownFiles = @(
    'CodexUsageOverlay.ps1', 'CodexOverlayWatcher.ps1', 'Get-CodexAccounts.ps1',
    'Switch-CodexAccount.ps1', 'Remove-CodexAccount.ps1', 'Start-CodexAuthLogin.ps1', 'Start-CodexUsageOverlay.vbs',
    'Start-CodexOverlayWatcher.vbs', 'Restart-CodexUsageOverlay.vbs', 'config.example.json',
    'Install.ps1', 'Uninstall.ps1', 'README.md', 'README.txt', 'PRIVACY.md', 'SECURITY.md',
    'THIRD_PARTY_NOTICES.md', 'LICENSE', 'VERSION', 'position.json', 'runtime-status.json',
    'warning-state.json', 'install-manifest.json'
)

foreach ($directory in $ownedDirectories) {
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }

    $ownedMarkerPresent = @(
        'CodexUsageOverlay.ps1', 'CodexOverlayWatcher.ps1', 'install-manifest.json', 'README.txt'
    ) | Where-Object { Test-Path -LiteralPath (Join-Path $directory $_) -PathType Leaf }
    if (@($ownedMarkerPresent).Count -eq 0) { continue }
    $foundOverlayArtifact = $true

    $knownFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $fixedKnownFiles) { $null = $knownFiles.Add($name) }
    if (-not $KeepConfig) { $null = $knownFiles.Add('config.json') }

    $manifestPath = Join-Path $directory 'install-manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            foreach ($name in @($manifest.files)) {
                $text = [string]$name
                if ([IO.Path]::GetFileName($text) -eq $text -and $text -notin @('.', '..')) {
                    $null = $knownFiles.Add($text)
                }
            }
        } catch {
            Write-Warning "Install manifest in $directory could not be read; only the fixed safe file list will be removed."
        }
    }

    foreach ($name in $knownFiles) {
        $filePath = Join-Path $directory $name
        if ((Test-Path -LiteralPath $filePath -PathType Leaf) -and $PSCmdlet.ShouldProcess($filePath, 'Remove installed overlay file')) {
            Remove-Item -LiteralPath $filePath -Force
        }
    }

    $logFile = Join-Path $directory 'logs\overlay.log'
    if ((Test-Path -LiteralPath $logFile -PathType Leaf) -and $PSCmdlet.ShouldProcess($logFile, 'Remove overlay log')) {
        Remove-Item -LiteralPath $logFile -Force
    }
    $logDirectory = Join-Path $directory 'logs'
    if ((Test-Path -LiteralPath $logDirectory -PathType Container) -and @(Get-ChildItem -LiteralPath $logDirectory -Force).Count -eq 0) {
        if ($PSCmdlet.ShouldProcess($logDirectory, 'Remove empty log directory')) { Remove-Item -LiteralPath $logDirectory -Force }
    }
    if ((Test-Path -LiteralPath $directory -PathType Container) -and @(Get-ChildItem -LiteralPath $directory -Force).Count -eq 0) {
        if ($PSCmdlet.ShouldProcess($directory, 'Remove empty installation directory')) { Remove-Item -LiteralPath $directory -Force }
    }
}

if (-not $foundOverlayArtifact) {
    Write-Host 'Codex Usage Overlay is not installed in a known location.'
    exit 0
}

if ($WhatIfPreference) {
    Write-Host 'Uninstall dry run completed. No files, processes, tasks, shortcuts, settings, or account data were changed.'
    exit 0
}

Write-Host 'Codex Usage Overlay was removed. codex-auth and all Codex/OpenAI account data were left untouched.' -ForegroundColor Green
