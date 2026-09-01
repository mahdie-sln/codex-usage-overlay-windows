param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 999)]
    [int]$RowNumber,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$ExpectedLabelHash,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('(?i)^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$')]
    [string]$ExpectedEmail,

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
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

try {
    $cliPath = Get-CodexAuthPath
    if (-not $cliPath) { exit 10 }

    # Re-check the local account list immediately before removal. This prevents
    # a stale row or changed account label from removing a different account.
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
    $email = $null
    foreach ($line in $lines) {
        if ($line.Length -lt $planStart) { continue }
        $prefix = $line.Substring(0, $accountStart)
        if ($prefix -notmatch '^\s*(?:\*)?\s*(?<number>\d+)\s*$') { continue }
        if ([int]$Matches.number -ne $RowNumber) { continue }
        $label = $line.Substring($accountStart, $planStart - $accountStart).Trim()
        $emailMatch = [regex]::Match($label, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b')
        if ($emailMatch.Success) { $email = $emailMatch.Value }
        break
    }

    if ([string]::IsNullOrWhiteSpace($label) -or [string]::IsNullOrWhiteSpace($email)) { exit 12 }
    if ((Get-Sha256Hex -Text $label) -ne $ExpectedLabelHash.ToLowerInvariant()) { exit 12 }
    if (-not $email.Equals($ExpectedEmail, [StringComparison]::OrdinalIgnoreCase)) { exit 12 }

    # codex-auth has no separate logout command. Its exact-query remove form is
    # `remove <email>`; combining a query with --skip-api is rejected by the CLI.
    # Output is discarded, and native stderr cannot turn a completed CLI call
    # into a PowerShell exception.
    $removeExitCode = 13
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $cliPath remove $ExpectedEmail 1>$null 2>$null
        $removeExitCode = [int]$LASTEXITCODE
    } catch {
        $removeExitCode = 13
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($removeExitCode -ne 0) { exit 13 }

    # Confirm that the selected email is no longer present. This prevents the
    # overlay from claiming success if an upstream CLI version only logged out
    # or otherwise left the local account registry unchanged.
    try {
        $verifyRaw = (& $cliPath list --skip-api 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { exit 15 }
        $verifyPlain = [regex]::Replace($verifyRaw, [char]27 + '\[[0-?]*[ -/]*[@-~]', '')
        $emailPattern = '(?i)(?<![A-Z0-9._%+-])' + [regex]::Escape($ExpectedEmail) + '(?![A-Z0-9._%+-])'
        if ($verifyPlain -match $emailPattern) { exit 15 }
    } catch {
        exit 15
    }
    exit 0
} catch {
    exit 14
}
