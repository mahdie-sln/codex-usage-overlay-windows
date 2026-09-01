[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Programs\CodexUsageOverlay'),
    [string]$LegacyInstallDirectory = '',
    [switch]$AcceptCodexAuthApiRisk,
    [switch]$NoAutostart,
    [switch]$NoShortcuts,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$taskName = 'Codex Usage Overlay'
$sourceDirectory = $PSScriptRoot

function Resolve-AbsolutePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'InstallDirectory cannot be empty.' }
    return [IO.Path]::GetFullPath($Path)
}

function Confirm-ApiUsageRisk {
    if ($AcceptCodexAuthApiRisk) { return }

    Write-Host ''
    Write-Host 'IMPORTANT PRIVACY AND ACCOUNT NOTICE' -ForegroundColor Yellow
    Write-Host 'This overlay runs "codex-auth list --api" every 60 seconds by default.'
    Write-Host 'The third-party codex-auth tool sends the locally stored ChatGPT access token'
    Write-Host 'to OpenAI usage/account endpoints. The overlay never prints, copies, or logs it.'
    Write-Host 'The codex-auth project warns that API mode may carry account/terms risk.'
    Write-Host 'Review PRIVACY.md and the codex-auth project before continuing.'
    Write-Host ''
    $answer = Read-Host 'Type I AGREE to enable API-backed usage refresh'
    if ($answer -cne 'I AGREE') { throw 'Installation cancelled: API usage consent was not granted.' }
}

function Stop-ExistingOverlayRuntime {
    param([string[]]$OwnedDirectories)

    $directories = @($OwnedDirectories | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        [IO.Path]::GetFullPath($_).TrimEnd('\')
    } | Select-Object -Unique)

    # Disable the watcher first so it cannot recreate the old overlay between
    # process discovery and shutdown.
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $taskOwned = @($task.Actions | Where-Object {
            $arguments = [string]$_.Arguments
            $arguments -match '(?i)CodexOverlayWatcher\.ps1' -and @($directories | Where-Object {
                $arguments.IndexOf(($_ + '\'), [StringComparison]::OrdinalIgnoreCase) -ge 0
            }).Count -gt 0
        }).Count -gt 0
        if ($taskOwned) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $ownedProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $commandLine = [string]$_.CommandLine
            $isOverlayRuntime = $commandLine -match '(?i)(?:CodexUsageOverlay|CodexOverlayWatcher)\.ps1'
            $isOwnedPath = @($directories | Where-Object {
                $commandLine.IndexOf(($_ + '\'), [StringComparison]::OrdinalIgnoreCase) -ge 0
            }).Count -gt 0
            $isOverlayRuntime -and $isOwnedPath
        })
        if ($ownedProcesses.Count -eq 0) { return }
        foreach ($process in $ownedProcesses) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 150
    }

    $remainingProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $commandLine = [string]$_.CommandLine
        $commandLine -match '(?i)(?:CodexUsageOverlay|CodexOverlayWatcher)\.ps1' -and @($directories | Where-Object {
            $commandLine.IndexOf(($_ + '\'), [StringComparison]::OrdinalIgnoreCase) -ge 0
        }).Count -gt 0
    })
    if ($remainingProcesses.Count -gt 0) {
        throw 'A previous Codex Usage Overlay process could not be stopped. Restart Windows and run the installer again.'
    }
}

function Remove-PreviousOverlayStartupShortcut {
    param([string[]]$OwnedDirectories)

    $shortcutPath = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)) 'Codex Usage Overlay.lnk'
    if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { return }
    $shell = New-Object -ComObject 'WScript.Shell'
    $shortcut = $null
    try {
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $arguments = [string]$shortcut.Arguments
        $owned = $arguments -match '(?i)Start-CodexUsageOverlay\.vbs' -and @($OwnedDirectories | Where-Object {
            $directoryPrefix = [IO.Path]::GetFullPath($_).TrimEnd('\') + '\'
            $arguments.IndexOf($directoryPrefix, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }).Count -gt 0
        if ($owned) { Remove-Item -LiteralPath $shortcutPath -Force }
    } finally {
        foreach ($item in @($shortcut, $shell)) {
            if ($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) | Out-Null
            }
        }
    }
}

function Register-OverlayAutostart {
    param([string]$TargetDirectory)

    $scheduler = $null
    $rootFolder = $null
    $definition = $null
    $trigger = $null
    $action = $null
    $registeredTask = $null
    try {
        $scheduler = New-Object -ComObject 'Schedule.Service'
        $scheduler.Connect()
        $rootFolder = $scheduler.GetFolder('\')
        $definition = $scheduler.NewTask(0)
        $definition.RegistrationInfo.Description = 'Watch for the Codex desktop app and start the usage overlay when Codex opens.'
        $definition.Settings.Enabled = $true
        $definition.Settings.AllowDemandStart = $true
        $definition.Settings.StartWhenAvailable = $true
        $definition.Settings.DisallowStartIfOnBatteries = $false
        $definition.Settings.StopIfGoingOnBatteries = $false
        $definition.Settings.ExecutionTimeLimit = 'PT0S'
        $definition.Settings.MultipleInstances = 2

        $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $definition.Principal.UserId = $userId
        $definition.Principal.LogonType = 3
        $definition.Principal.RunLevel = 0

        $trigger = $definition.Triggers.Create(9)
        $trigger.Enabled = $true
        $trigger.UserId = $userId

        $watcherPath = Join-Path $TargetDirectory 'CodexOverlayWatcher.ps1'
        $action = $definition.Actions.Create(0)
        $action.Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $watcherPath
        $action.WorkingDirectory = $TargetDirectory

        $registeredTask = $rootFolder.RegisterTaskDefinition($taskName, $definition, 6, $userId, $null, 3, $null)
        $null = $registeredTask.Run($null)
    } finally {
        foreach ($item in @($registeredTask, $action, $trigger, $definition, $rootFolder, $scheduler)) {
            if ($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) | Out-Null
            }
        }
    }
}

function New-OverlayShortcut {
    param(
        [string]$ShortcutPath,
        [string]$TargetDirectory
    )

    $shell = New-Object -ComObject 'WScript.Shell'
    $shortcut = $null
    try {
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $shortcut.Arguments = '"{0}"' -f (Join-Path $TargetDirectory 'Start-CodexUsageOverlay.vbs')
        $shortcut.WorkingDirectory = $TargetDirectory
        $shortcut.Description = 'Open Codex Usage Overlay'
        $shortcut.Save()
    } finally {
        foreach ($item in @($shortcut, $shell)) {
            if ($null -ne $item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) {
                [Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) | Out-Null
            }
        }
    }
}

Confirm-ApiUsageRisk

$targetDirectory = Resolve-AbsolutePath -Path $InstallDirectory
if ([IO.Path]::GetPathRoot($targetDirectory).TrimEnd('\') -eq $targetDirectory.TrimEnd('\')) {
    throw 'Refusing to install directly into a drive root.'
}

$legacyDirectory = $null
if (-not [string]::IsNullOrWhiteSpace($LegacyInstallDirectory)) {
    $legacyDirectory = Resolve-AbsolutePath -Path $LegacyInstallDirectory
} elseif (-not $PSBoundParameters.ContainsKey('InstallDirectory')) {
    $legacyDirectory = Join-Path ([IO.Path]::GetPathRoot($env:SystemRoot)) 'Tools\CodexUsageOverlay'
}
$ownedRuntimeDirectories = @($targetDirectory)
if ($legacyDirectory -and -not $legacyDirectory.Equals($targetDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    $ownedRuntimeDirectories += $legacyDirectory
}

$payloadFiles = @(
    'src\CodexUsageOverlay.ps1',
    'src\CodexOverlayWatcher.ps1',
    'src\Get-CodexAccounts.ps1',
    'src\Switch-CodexAccount.ps1',
    'src\Remove-CodexAccount.ps1',
    'src\Start-CodexAuthLogin.ps1',
    'src\Start-CodexUsageOverlay.vbs',
    'src\Start-CodexOverlayWatcher.vbs',
    'src\Restart-CodexUsageOverlay.vbs',
    'src\config.example.json',
    'Uninstall.ps1'
)

foreach ($name in $payloadFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory $name) -PathType Leaf)) {
        throw "Required package file is missing: $name"
    }
}

# Validate the complete package before interrupting an installed overlay.
Remove-PreviousOverlayStartupShortcut -OwnedDirectories $ownedRuntimeDirectories
Stop-ExistingOverlayRuntime -OwnedDirectories $ownedRuntimeDirectories

$null = New-Item -ItemType Directory -Path $targetDirectory -Force
foreach ($name in $payloadFiles) {
    $targetName = Split-Path -Leaf $name
    Copy-Item -LiteralPath (Join-Path $sourceDirectory $name) -Destination (Join-Path $targetDirectory $targetName) -Force
}

$configPath = Join-Path $targetDirectory 'config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf) -and $legacyDirectory) {
    $legacyConfigPath = Join-Path $legacyDirectory 'config.json'
    $legacyOverlayPath = Join-Path $legacyDirectory 'CodexUsageOverlay.ps1'
    if ((Test-Path -LiteralPath $legacyOverlayPath -PathType Leaf) -and (Test-Path -LiteralPath $legacyConfigPath -PathType Leaf)) {
        Copy-Item -LiteralPath $legacyConfigPath -Destination $configPath -Force
    }
}
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
} else {
    $config = Get-Content -LiteralPath (Join-Path $sourceDirectory 'src\config.example.json') -Raw | ConvertFrom-Json
}
if ($null -eq $config.PSObject.Properties['apiUsageConsent']) {
    $config | Add-Member -NotePropertyName apiUsageConsent -NotePropertyValue $true
} else {
    $config.apiUsageConsent = $true
}
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8

$positionPath = Join-Path $targetDirectory 'position.json'
if (-not (Test-Path -LiteralPath $positionPath -PathType Leaf) -and $legacyDirectory) {
    $legacyPositionPath = Join-Path $legacyDirectory 'position.json'
    $legacyOverlayPath = Join-Path $legacyDirectory 'CodexUsageOverlay.ps1'
    if ((Test-Path -LiteralPath $legacyOverlayPath -PathType Leaf) -and (Test-Path -LiteralPath $legacyPositionPath -PathType Leaf)) {
        Copy-Item -LiteralPath $legacyPositionPath -Destination $positionPath -Force
    }
}

$installedPayloadNames = @($payloadFiles | ForEach-Object { Split-Path -Leaf $_ })
$manifest = [ordered]@{
    product = 'Codex Usage Overlay & Multi-Account Manager'
    installedAtUtc = [DateTime]::UtcNow.ToString('o')
    files = @($installedPayloadNames + 'config.json')
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $targetDirectory 'install-manifest.json') -Encoding UTF8

if (-not $NoShortcuts) {
    $desktopShortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)) 'Codex Usage Overlay.lnk'
    $programsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    $startMenuShortcut = Join-Path $programsDirectory 'Codex Usage Overlay.lnk'
    New-OverlayShortcut -ShortcutPath $desktopShortcut -TargetDirectory $targetDirectory
    New-OverlayShortcut -ShortcutPath $startMenuShortcut -TargetDirectory $targetDirectory
}

if (-not $NoAutostart) {
    Register-OverlayAutostart -TargetDirectory $targetDirectory
}

if (-not $NoLaunch) {
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"{0}"' -f (Join-Path $targetDirectory 'Start-CodexUsageOverlay.vbs')) -WindowStyle Hidden
}

$codexAuth = Get-Command 'codex-auth.cmd' -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Host ''
Write-Host 'Codex Usage Overlay & Multi-Account Manager installed.' -ForegroundColor Green
Write-Host "Location: $targetDirectory"
Write-Host ('Autostart: {0}' -f $(if ($NoAutostart) { 'disabled' } else { 'enabled when Codex opens' }))
if (-not $codexAuth) {
    Write-Warning 'codex-auth was not found. Install @loongphy/codex-auth before starting the overlay.'
}
