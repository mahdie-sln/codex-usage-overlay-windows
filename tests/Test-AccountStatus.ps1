$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\AccountStatus.ps1')

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw ('{0}: expected {1}, got {2}' -f $Message, $Expected, $Actual) }
}

$offset = [TimeZoneInfo]::Local.GetUtcOffset([DateTime]::new(2026, 11, 1))
$now = [DateTimeOffset]::new(2026, 11, 1, 9, 0, 0, $offset)
$summary = Get-AccountEndSummary -EndDate '2026-11-24' -Now $now
Assert-Equal $summary.daysText '23 days left' 'Days until paid access ends'
Assert-Equal (Get-AccountEndSummary -EndDate '' -Now $now).daysText 'End date unknown' 'Missing end date stays unknown'
Assert-Equal (Get-AccountEndSummary -EndDate '2026-10-31' -Now $now).daysText 'Expired' 'Past date shows expired'
Assert-Equal (Get-AccountEndSummary -EndDate 'invalid' -Now $now).daysText 'End date unknown' 'Invalid end date stays unknown'

$testPath = Join-Path ([IO.Path]::GetTempPath()) ('CodexUsageOverlay-SignedOut-{0}.json' -f $PID)
if (Test-Path -LiteralPath $testPath) { throw 'Refusing to reuse a signed-out account test file.' }
try {
    $accounts = @(
        [pscustomobject]@{ email = 'first@example.com'; plan = 'Plus' },
        [pscustomobject]@{ email = 'FIRST@example.com'; plan = 'Plus' },
        [pscustomobject]@{ email = 'invalid'; plan = 'Plus' }
    )
    Write-SignedOutAccounts -Path $testPath -Accounts $accounts
    $roundTrip = @(Read-SignedOutAccounts -Path $testPath)
    Assert-Equal $roundTrip.Count 1 'Only one valid saved email remains'
    Assert-Equal $roundTrip[0].email 'first@example.com' 'Saved email is preserved'
    Assert-Equal $roundTrip[0].plan 'Plus' 'Saved plan label is preserved'
    $raw = Get-Content -Raw -LiteralPath $testPath
    if ($raw -match '(?i)token|password|authorization') { throw 'Signed-out state contains an unexpected secret marker.' }
    Write-SignedOutAccounts -Path $testPath -Accounts @()
    Assert-Equal @(Read-SignedOutAccounts -Path $testPath).Count 0 'Cleared reminders stay empty'
} finally {
    if (Test-Path -LiteralPath $testPath) { Remove-Item -LiteralPath $testPath -Force }
}

Write-Host 'Account end-date math and signed-out reminder storage passed.' -ForegroundColor Green
