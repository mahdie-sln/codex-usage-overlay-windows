param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 999)]
    [int]$RowNumber,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedLabelHash,

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
    if (Test-Path -LiteralPath $knownPath -PathType Leaf) {
        return (Get-Item -LiteralPath $knownPath).FullName
    }

    foreach ($name in @('codex-auth.cmd', 'codex-auth')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            return $command.Source
        }
    }
    return $null
}

function Get-Sha256Hex {
    param([string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

try {
    $cliPath = Get-CodexAuthPath
    if (-not $cliPath) { exit 10 }

    # Re-check the local, non-API list immediately before switching so a stale row
    # number can never select a different account after the menu was rendered.
    $raw = (& $cliPath list --skip-api 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { exit 11 }
    $plain = [regex]::Replace($raw, [char]27 + '\[[0-?]*[ -/]*[@-~]', '')
    $lines = @($plain -split '\r?\n')
    $header = $lines | Where-Object { $_ -match 'ACCOUNT' -and $_ -match 'PLAN' -and $_ -match '5H USAGE' } | Select-Object -First 1
    if (-not $header) { exit 11 }
    $accountStart = $header.IndexOf('ACCOUNT')
    $planStart = $header.IndexOf('PLAN')
    if ($accountStart -lt 1 -or $planStart -le $accountStart) { exit 11 }

    $label = $null
    foreach ($line in $lines) {
        if ($line.Length -lt $planStart) { continue }
        $prefix = $line.Substring(0, $accountStart)
        if ($prefix -notmatch '^\s*(?:\*)?\s*(?<number>\d+)\s*$') { continue }
        if ([int]$Matches.number -ne $RowNumber) { continue }
        $label = $line.Substring($accountStart, $planStart - $accountStart).Trim()
        break
    }

    if ([string]::IsNullOrWhiteSpace($label)) { exit 12 }
    if ((Get-Sha256Hex -Text $label) -ne $ExpectedLabelHash.ToLowerInvariant()) { exit 12 }

    # This is the only account-changing operation in the overlay. It is reached
    # solely after the user clicks a specific account row.
    [string]$RowNumber | & $cliPath switch --skip-api 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) { exit 13 }
    exit 0
} catch {
    exit 14
}
