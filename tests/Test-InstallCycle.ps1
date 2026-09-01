$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$expectedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testDirectory = Join-Path $expectedTempRoot ("CodexUsageOverlay-PackageTest-{0}" -f $PID)
$legacyDirectory = Join-Path $expectedTempRoot ("CodexUsageOverlay-LegacyTest-{0}" -f $PID)
$resolvedTestDirectory = [IO.Path]::GetFullPath($testDirectory)
$resolvedLegacyDirectory = [IO.Path]::GetFullPath($legacyDirectory)
foreach ($directory in @($resolvedTestDirectory, $resolvedLegacyDirectory)) {
    if (-not $directory.StartsWith($expectedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Test directory escaped the Windows temporary directory.'
    }
    if (Test-Path -LiteralPath $directory) {
        throw "Refusing to reuse an existing test directory: $directory"
    }
}

$legacyProcess = $null
try {
    $null = New-Item -ItemType Directory -Path $resolvedLegacyDirectory
    $legacyOverlayPath = Join-Path $resolvedLegacyDirectory 'CodexUsageOverlay.ps1'
    @'
while ($true) { Start-Sleep -Seconds 30 }
'@ | Set-Content -LiteralPath $legacyOverlayPath -Encoding UTF8

    $legacyConfig = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\config.example.json') -Raw | ConvertFrom-Json
    $legacyConfig.opacity = 0.73
    $legacyConfig | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $resolvedLegacyDirectory 'config.json') -Encoding UTF8
    '{"left":120,"top":80}' | Set-Content -LiteralPath (Join-Path $resolvedLegacyDirectory 'position.json') -Encoding UTF8

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $legacyProcess = Start-Process -FilePath $powerShellPath `
        -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $legacyOverlayPath) `
        -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 400
    $legacyProcess.Refresh()
    if ($legacyProcess.HasExited) { throw 'Legacy-process fixture exited before migration testing.' }

    & (Join-Path $repositoryRoot 'Install.ps1') `
        -InstallDirectory $resolvedTestDirectory `
        -LegacyInstallDirectory $resolvedLegacyDirectory `
        -AcceptCodexAuthApiRisk `
        -NoAutostart `
        -NoShortcuts `
        -NoLaunch

    $legacyProcess.Refresh()
    if (-not $legacyProcess.HasExited) { throw 'Installer left the legacy overlay process running.' }

    $requiredInstalledFiles = @(
        'CodexUsageOverlay.ps1', 'CodexOverlayWatcher.ps1', 'Get-CodexAccounts.ps1',
        'Switch-CodexAccount.ps1', 'Start-CodexAuthLogin.ps1', 'Start-CodexUsageOverlay.vbs',
        'Remove-CodexAccount.ps1', 'Restart-CodexUsageOverlay.vbs', 'config.json',
        'position.json', 'install-manifest.json', 'Uninstall.ps1'
    )
    foreach ($name in $requiredInstalledFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $resolvedTestDirectory $name) -PathType Leaf)) {
            throw "Install-cycle test is missing: $name"
        }
    }

    $config = Get-Content -LiteralPath (Join-Path $resolvedTestDirectory 'config.json') -Raw | ConvertFrom-Json
    if (-not [bool]$config.apiUsageConsent) { throw 'Installer did not record explicit API usage consent.' }
    if ([Math]::Abs([double]$config.opacity - 0.73) -gt 0.001) { throw 'Installer did not migrate the legacy configuration.' }
    if (-not [string]::IsNullOrWhiteSpace([string]$config.codexAuthExecutable)) { throw 'Installer introduced a machine-specific codex-auth path.' }
    $manifest = Get-Content -LiteralPath (Join-Path $resolvedTestDirectory 'install-manifest.json') -Raw | ConvertFrom-Json
    if ($null -ne $manifest.PSObject.Properties['version']) { throw 'Versionless release wrote a placeholder version to the manifest.' }

    & (Join-Path $resolvedTestDirectory 'Uninstall.ps1') `
        -InstallDirectory $resolvedTestDirectory `
        -LegacyInstallDirectory $resolvedLegacyDirectory `
        -Confirm:$false
    foreach ($directory in @($resolvedTestDirectory, $resolvedLegacyDirectory)) {
        if (Test-Path -LiteralPath $directory) {
            $remaining = @(Get-ChildItem -LiteralPath $directory -Force | Select-Object -ExpandProperty Name)
            throw "Install-cycle test left files behind in $directory`: $($remaining -join ', ')"
        }
    }
} finally {
    if ($legacyProcess) {
        $legacyProcess.Refresh()
        if (-not $legacyProcess.HasExited) { Stop-Process -Id $legacyProcess.Id -Force -ErrorAction SilentlyContinue }
        $legacyProcess.Dispose()
    }
    foreach ($directory in @($resolvedTestDirectory, $resolvedLegacyDirectory)) {
        if ($directory.StartsWith($expectedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $directory)) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
    }
}

Write-Host 'Install/uninstall migration cycle passed without starting the real overlay or touching account data.' -ForegroundColor Green
