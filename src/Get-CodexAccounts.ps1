param(
    [string]$CodexAuthExecutable = ''
)

$ErrorActionPreference = 'Stop'

function Write-Result {
    param($Value)

    $Value | ConvertTo-Json -Depth 10 -Compress
}

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

function Get-FixedColumn {
    param(
        [string]$Line,
        [int]$Start,
        [int]$End
    )

    if ($Start -lt 0 -or $Start -ge $Line.Length) { return '' }
    $safeEnd = [Math]::Min($Line.Length, $End)
    if ($safeEnd -le $Start) { return '' }
    return $Line.Substring($Start, $safeEnd - $Start).Trim()
}

function Convert-ResetTextToEpoch {
    param([string]$ResetText)

    if ([string]::IsNullOrWhiteSpace($ResetText)) { return $null }
    if ($ResetText -notmatch '^(?<time>\d{1,2}:\d{2})(?:\s+on\s+(?<day>\d{1,2})\s+(?<month>[A-Za-z]{3}))?$') {
        return $null
    }

    try {
        $now = [DateTimeOffset]::Now
        $culture = [Globalization.CultureInfo]::InvariantCulture
        if ($Matches.day) {
            $text = '{0} {1} {2} {3}' -f $Matches.day, $Matches.month, $now.Year, $Matches.time
            $candidate = [DateTime]::ParseExact(
                $text,
                'd MMM yyyy HH:mm',
                $culture,
                [Globalization.DateTimeStyles]::AllowWhiteSpaces
            )
            if ($candidate -lt $now.LocalDateTime.AddDays(-1)) {
                $candidate = $candidate.AddYears(1)
            }
        } else {
            $time = [TimeSpan]::ParseExact($Matches.time, 'h\:mm', $culture)
            $candidate = $now.LocalDateTime.Date.Add($time)
            if ($candidate -lt $now.LocalDateTime.AddMinutes(-2)) {
                $candidate = $candidate.AddDays(1)
            }
        }

        $offset = [TimeZoneInfo]::Local.GetUtcOffset($candidate)
        return [DateTimeOffset]::new($candidate, $offset).ToUnixTimeSeconds()
    } catch {
        return $null
    }
}

function Convert-UsageCell {
    param([string]$Text)

    $value = $Text.Trim()
    if ($value -match '^(?<remaining>\d+(?:\.\d+)?)%\s*(?:\((?<reset>[^)]+)\))?$') {
        # codex-auth list --api already formats this value as remaining usage.
        # Keep the CLI's value as-is; subtracting it from 100 would invert it twice.
        $reportedRemaining = [double]::Parse($Matches.remaining, [Globalization.CultureInfo]::InvariantCulture)
        $reportedRemaining = [Math]::Max(0, [Math]::Min(100, $reportedRemaining))
        $remaining = [int][Math]::Round($reportedRemaining, 0, [MidpointRounding]::AwayFromZero)
        $resetText = if ($Matches.reset) { [string]$Matches.reset } else { $null }
        return [pscustomobject][ordered]@{
            status = 'ok'
            remainingPercent = $remaining
            resetText = $resetText
            resetEpochSeconds = Convert-ResetTextToEpoch -ResetText $resetText
        }
    }

    if ($value -match '^\d{3}$') {
        return [pscustomobject][ordered]@{
            status = 'http_error'
            statusCode = $value
            remainingPercent = $null
            resetText = $null
            resetEpochSeconds = $null
        }
    }

    if ($value -match '^[A-Za-z][A-Za-z0-9_-]{0,31}$') {
        return [pscustomobject][ordered]@{
            status = 'api_error'
            errorName = $value
            remainingPercent = $null
            resetText = $null
            resetEpochSeconds = $null
        }
    }

    return [pscustomobject][ordered]@{
        status = 'unavailable'
        remainingPercent = $null
        resetText = $null
        resetEpochSeconds = $null
    }
}

try {
    $cliPath = Get-CodexAuthPath
    if (-not $cliPath) {
        Write-Result ([ordered]@{ ok = $false; errorCode = 'codex_auth_not_found'; accounts = @() })
        exit 0
    }

    # Raw command output stays in memory. It is never written to disk or returned on errors.
    $raw = (& $cliPath list --api 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Result ([ordered]@{ ok = $false; errorCode = 'codex_auth_list_failed'; exitCode = $exitCode; accounts = @() })
        exit 0
    }

    $plain = [regex]::Replace($raw, [char]27 + '\[[0-?]*[ -/]*[@-~]', '')
    $lines = @($plain -split '\r?\n')
    $header = $lines | Where-Object {
        $_ -match 'ACCOUNT' -and $_ -match 'PLAN' -and $_ -match '5H USAGE' -and $_ -match 'WEEKLY USAGE' -and $_ -match 'LAST ACTIVITY'
    } | Select-Object -First 1

    if (-not $header) {
        Write-Result ([ordered]@{ ok = $false; errorCode = 'unexpected_output'; accounts = @() })
        exit 0
    }

    $accountStart = $header.IndexOf('ACCOUNT')
    $planStart = $header.IndexOf('PLAN')
    $fiveStart = $header.IndexOf('5H USAGE')
    $weeklyStart = $header.IndexOf('WEEKLY USAGE')
    $lastStart = $header.IndexOf('LAST ACTIVITY')
    if ($accountStart -lt 1 -or $planStart -le $accountStart -or $fiveStart -le $planStart -or $weeklyStart -le $fiveStart -or $lastStart -le $weeklyStart) {
        Write-Result ([ordered]@{ ok = $false; errorCode = 'unexpected_output'; accounts = @() })
        exit 0
    }

    $accounts = [Collections.Generic.List[object]]::new()
    foreach ($line in $lines) {
        if ($line.Length -lt $accountStart) { continue }
        $prefix = $line.Substring(0, $accountStart)
        if ($prefix -notmatch '^\s*(?<active>\*)?\s*(?<number>\d+)\s*$') { continue }

        $accountLabel = Get-FixedColumn -Line $line -Start $accountStart -End $planStart
        if ([string]::IsNullOrWhiteSpace($accountLabel)) { continue }
        $emailMatch = [regex]::Match($accountLabel, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b')
        $email = if ($emailMatch.Success) { $emailMatch.Value } else { $accountLabel }

        $accounts.Add([pscustomobject][ordered]@{
            rowNumber = [int]$Matches.number
            active = -not [string]::IsNullOrWhiteSpace($Matches.active)
            accountLabel = $accountLabel
            email = $email
            plan = Get-FixedColumn -Line $line -Start $planStart -End $fiveStart
            fiveHour = Convert-UsageCell (Get-FixedColumn -Line $line -Start $fiveStart -End $weeklyStart)
            weekly = Convert-UsageCell (Get-FixedColumn -Line $line -Start $weeklyStart -End $lastStart)
            lastActivity = $line.Substring([Math]::Min($lastStart, $line.Length)).Trim()
        })
    }

    if ($accounts.Count -eq 0) {
        Write-Result ([ordered]@{ ok = $false; errorCode = 'no_accounts_parsed'; accounts = @() })
        exit 0
    }

    Write-Result ([ordered]@{
        ok = $true
        source = 'codex-auth list --api'
        fetchedAtUtc = [DateTime]::UtcNow.ToString('o')
        accountCount = $accounts.Count
        accounts = @($accounts)
    })
} catch {
    Write-Result ([ordered]@{ ok = $false; errorCode = 'reader_failed'; accounts = @() })
}
