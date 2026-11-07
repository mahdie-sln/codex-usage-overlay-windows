function Get-AccountEndSummary {
    param(
        [string]$EndDate,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    $result = [ordered]@{ daysText = 'End date unknown'; endDate = $null }
    if ([string]::IsNullOrWhiteSpace($EndDate)) { return [pscustomobject]$result }
    try {
        $date = [DateTime]::ParseExact($EndDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $days = [int]($date.Date - $Now.LocalDateTime.Date).TotalDays
        $result.endDate = $EndDate
        if ($days -lt 0) { $result.daysText = 'Expired'; return [pscustomobject]$result }
        if ($days -eq 0) { $result.daysText = 'Ends today'; return [pscustomobject]$result }
        $result.daysText = if ($days -eq 1) { '1 day left' } else { '{0} days left' -f $days }
    } catch {
        return [pscustomobject]@{ daysText = 'End date unknown'; endDate = $null }
    }
    return [pscustomobject]$result
}

function Test-SafeAccountEmail {
    param([string]$Email)
    return (-not [string]::IsNullOrWhiteSpace($Email) -and $Email.Length -le 180 -and
        $Email -match '(?i)^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$')
}

function Read-SignedOutAccounts {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $raw = [IO.File]::ReadAllText($Path)
        if ($raw.Length -gt 65536) { return @() }
        $loaded = @(ConvertFrom-Json -InputObject $raw)
        $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $accounts = [Collections.Generic.List[object]]::new()
        foreach ($item in $loaded) {
            $email = [string]$item.email
            if (-not (Test-SafeAccountEmail $email) -or -not $unique.Add($email)) { continue }
            $plan = ([string]$item.plan -replace '[\x00-\x1F]', '').Trim()
            if ($plan.Length -gt 32) { $plan = $plan.Substring(0, 32) }
            $accounts.Add([pscustomobject]@{ email = $email; plan = $plan })
            if ($accounts.Count -ge 200) { break }
        }
        return @($accounts)
    } catch { return @() }
}

function Write-SignedOutAccounts {
    param([string]$Path, [object[]]$Accounts)
    $safe = [Collections.Generic.List[object]]::new()
    $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Accounts)) {
        $email = [string]$item.email
        if (-not (Test-SafeAccountEmail $email) -or -not $unique.Add($email)) { continue }
        $safe.Add([ordered]@{ email = $email; plan = ([string]$item.plan -replace '[\x00-\x1F]', '').Trim() })
        if ($safe.Count -ge 200) { break }
    }
    $temporaryPath = $Path + '.tmp'
    [IO.File]::WriteAllText($temporaryPath, (ConvertTo-Json -InputObject @($safe) -Depth 3), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}
