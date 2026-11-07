param(
    [string]$CachePath = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$usageEndpoint = 'https://chatgpt.com/backend-api/wham/usage'
$subscriptionEndpoint = 'https://chatgpt.com/backend-api/subscriptions'
$cacheSeconds = 300

function Write-SafeResult($Value) { $Value | ConvertTo-Json -Depth 5 -Compress }

function Get-CodexHome {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    if ($env:HOME) { return (Join-Path $env:HOME '.codex') }
    return (Join-Path $env:USERPROFILE '.codex')
}

function Get-SnapshotName([string]$Key) {
    if ($Key.Length -gt 512) { return $null }
    if ($Key -cmatch '^[A-Za-z0-9_.-]+$' -and $Key -notin @('.', '..')) { return ($Key + '.auth.json') }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Key)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return ($encoded + '.auth.json')
}

try {
    $accountsDir = Join-Path (Get-CodexHome) 'accounts'
    $registryPath = Join-Path $accountsDir 'registry.json'
    $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
    $records = @($registry.accounts)
    if ($records.Count -gt 200) { throw 'too many accounts' }

    if (-not $Force -and $CachePath -and (Test-Path -LiteralPath $CachePath -PathType Leaf)) {
        try {
            $cache = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
            $age = ([DateTime]::UtcNow - [datetime]$cache.fetchedAtUtc).TotalSeconds
            if ($age -ge 0 -and $age -lt $cacheSeconds -and [int]$cache.schemaVersion -eq 2 -and [int]$cache.accountCount -eq $records.Count) {
                Write-SafeResult $cache
                exit 0
            }
        } catch { }
    }

    $items = [Collections.Generic.List[object]]::new()
    $uniqueEmails = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $records) {
        $email = [string]$record.email
        $key = [string]$record.account_key
        if ($email -notmatch '(?i)^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$' -or -not $uniqueEmails.Add($email)) { continue }
        $name = Get-SnapshotName -Key $key
        if (-not $name) { continue }
        $path = Join-Path $accountsDir $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $auth = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $token = [string]$auth.tokens.access_token
            $accountId = [string]$auth.tokens.account_id
            if (-not $token -or -not $accountId -or $accountId -cne [string]$record.chatgpt_account_id) { continue }
            $count = $null
            $paidUntil = $null
            $willRenew = $null
            $checkedAtUtc = $null
            $subscriptionStatus = 'unavailable'
            $headers = @{ Authorization = 'Bearer ' + $token; 'ChatGPT-Account-Id' = $accountId; 'User-Agent' = 'CodexUsageOverlay/1' }
            try {
                $usage = Invoke-RestMethod -Method Get -Uri $usageEndpoint -Headers $headers -TimeoutSec 3
                if ($null -ne $usage.rate_limit_reset_credits.available_count) {
                    $parsedCount = [int]$usage.rate_limit_reset_credits.available_count
                    if ($parsedCount -ge 0 -and $parsedCount -le 999) { $count = $parsedCount }
                }
            } catch { }
            try {
                $uri = $subscriptionEndpoint + '?account_id=' + [Uri]::EscapeDataString($accountId)
                $subscription = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -TimeoutSec 3
                if ($subscription.is_active -eq $true -and [string]$subscription.plan_type -notmatch '^(?i:free)$' -and $subscription.active_until) {
                    $until = [DateTimeOffset]::Parse([string]$subscription.active_until, [Globalization.CultureInfo]::InvariantCulture)
                    if ($until.Year -ge 2020 -and $until.Year -le 2100) {
                        $paidUntil = $until.ToLocalTime().ToString('yyyy-MM-dd')
                        $checkedAtUtc = [DateTime]::UtcNow.ToString('o')
                        $subscriptionStatus = 'ok'
                        if ($subscription.will_renew -is [bool]) { $willRenew = [bool]$subscription.will_renew }
                    }
                } elseif ($subscription.is_active -eq $false -or [string]$subscription.plan_type -match '^(?i:free)$') {
                    $subscriptionStatus = 'not_paid'
                }
            } catch {
                if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -in @(401, 403)) {
                    $subscriptionStatus = 'auth_error'
                }
            }
            $items.Add([ordered]@{
                email = $email
                bankedResets = $count
                paidUntil = $paidUntil
                willRenew = $willRenew
                checkedAtUtc = $checkedAtUtc
                subscriptionStatus = $subscriptionStatus
            })
        } catch { }
        finally { $usage = $null; $subscription = $null; $headers = $null; $auth = $null; $token = $null }
    }
    $result = [ordered]@{ ok = $true; schemaVersion = 2; fetchedAtUtc = [DateTime]::UtcNow.ToString('o'); accountCount = $records.Count; accounts = @($items) }
    if ($CachePath) {
        try {
            $temporaryPath = $CachePath + '.tmp'
            [IO.File]::WriteAllText($temporaryPath, (ConvertTo-Json -InputObject $result -Depth 5), [Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $temporaryPath -Destination $CachePath -Force
        } catch { }
    }
    Write-SafeResult $result
} catch {
    Write-SafeResult ([ordered]@{ ok = $false; errorCode = 'account_extras_unavailable'; accounts = @() })
}
