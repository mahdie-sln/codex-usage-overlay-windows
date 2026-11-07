param(
    [string]$CodexAuthExecutable = '',
    [ValidatePattern('(?i)^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$')]
    [string]$ExpectedEmail = ''
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
if ($ExpectedEmail) {
    Write-Host ('Sign in with this email: {0}' -f $ExpectedEmail) -ForegroundColor Cyan
    Write-Host 'Enter the one-time code below on the OpenAI device page, then choose this email.'
} else {
    Write-Host 'Complete the device authorization in your browser. This window never displays or stores your token.'
}
Write-Host ''
try { Start-Process -FilePath 'https://auth.openai.com/codex/device' }
catch { Write-Host 'Open https://auth.openai.com/codex/device in your browser.' -ForegroundColor Yellow }
& $cliPath login --device-auth
$exitCode = $LASTEXITCODE
Write-Host ''
if ($exitCode -eq 0) {
    if ($ExpectedEmail) {
        $raw = (& $cliPath list --skip-api 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0 -or $raw -notmatch ('(?i)(?<![A-Z0-9._%+-])' + [regex]::Escape($ExpectedEmail) + '(?![A-Z0-9._%+-])')) {
            Write-Host 'The selected email was not found after login. Check which account you chose in the browser.' -ForegroundColor Yellow
        } else {
            Write-Host 'The selected account is signed in. The overlay will refresh automatically.' -ForegroundColor Green
        }
    } else {
        Write-Host 'Login finished. The overlay will refresh automatically.' -ForegroundColor Green
    }
} else {
    Write-Host ('Login did not complete (exit code {0}).' -f $exitCode) -ForegroundColor Yellow
}
Read-Host 'Press Enter to close'
exit $exitCode
