param(
    [string]$CodexAuthExecutable = ''
)

$ErrorActionPreference = 'Stop'

function Get-CodexAuthPath {
    if (-not [string]::IsNullOrWhiteSpace($CodexAuthExecutable)) {
        if (Test-Path -LiteralPath $CodexAuthExecutable -PathType Leaf) {
            return (Get-Item -LiteralPath $CodexAuthExecutable).FullName
        }
        return $null
    }
    $knownPath = Join-Path $env:APPDATA 'npm\codex-auth.cmd'
    if (Test-Path -LiteralPath $knownPath -PathType Leaf) { return $knownPath }
    $command = Get-Command 'codex-auth.cmd' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source) { return $command.Source }
    return $null
}

$cliPath = Get-CodexAuthPath
if (-not $cliPath) {
    Write-Host 'codex-auth was not found.' -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}

Write-Host 'Codex account login' -ForegroundColor Cyan
Write-Host 'Complete the device authorization in your browser. This window never displays or stores your token.'
Write-Host ''
& $cliPath login --device-auth
$exitCode = $LASTEXITCODE
Write-Host ''
if ($exitCode -eq 0) {
    Write-Host 'Login finished. The overlay will refresh automatically.' -ForegroundColor Green
} else {
    Write-Host ('Login did not complete (exit code {0}).' -f $exitCode) -ForegroundColor Yellow
}
Read-Host 'Press Enter to close'
exit $exitCode
