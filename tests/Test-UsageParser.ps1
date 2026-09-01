$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$expectedTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testDirectory = Join-Path $expectedTempRoot ("CodexUsageOverlay-ParserTest-{0}" -f $PID)
$testDirectory = [IO.Path]::GetFullPath($testDirectory)
if (-not $testDirectory.StartsWith($expectedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Test directory escaped the Windows temporary directory.'
}
if (Test-Path -LiteralPath $testDirectory) {
    throw "Refusing to reuse an existing test directory: $testDirectory"
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected'; received '$Actual'."
    }
}

try {
    $null = New-Item -ItemType Directory -Path $testDirectory
    $fakeCliPath = Join-Path $testDirectory 'codex-auth.ps1'
    $header = '     {0,-35}{1,-10}{2,-22}{3,-28}{4}' -f `
        'ACCOUNT', 'PLAN', '5H USAGE', 'WEEKLY USAGE', 'LAST ACTIVITY'
    $activeRow = '* 01 {0,-35}{1,-10}{2,-22}{3,-28}{4}' -f `
        'alpha@example.com', 'Plus', '68% (20:08)', '41% (08:42 on 5 Sep)', 'Now'
    $errorRow = '  02 {0,-35}{1,-10}{2,-22}{3,-28}{4}' -f `
        'beta@example.com', 'Plus', '401', 'rate_limit', '1h ago'
    @(
        '$global:LASTEXITCODE = 0'
        "@'"
        $header
        $activeRow
        $errorRow
        "'@"
    ) | Set-Content -LiteralPath $fakeCliPath -Encoding UTF8

    $powerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $readerPath = Join-Path $repositoryRoot 'src\Get-CodexAccounts.ps1'
    $output = & $powerShellPath -NoLogo -NoProfile -ExecutionPolicy Bypass `
        -File $readerPath -CodexAuthExecutable $fakeCliPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Usage reader exited with code $LASTEXITCODE."
    }

    $result = ($output | Out-String).Trim() | ConvertFrom-Json
    Assert-Equal $result.ok $true 'Reader did not report success.'
    Assert-Equal $result.accountCount 2 'Reader returned the wrong account count.'

    $active = $result.accounts[0]
    Assert-Equal $active.email 'alpha@example.com' 'Reader changed the account identifier.'
    Assert-Equal $active.active $true 'Reader did not preserve the active marker.'
    Assert-Equal $active.fiveHour.remainingPercent 68 '5-hour remaining usage was inverted or changed.'
    Assert-Equal $active.fiveHour.resetText '20:08' '5-hour reset text was not preserved.'
    Assert-Equal $active.weekly.remainingPercent 41 'Weekly remaining usage was inverted or changed.'
    Assert-Equal $active.weekly.resetText '08:42 on 5 Sep' 'Weekly reset text was not preserved.'
    if ($null -eq $active.fiveHour.resetEpochSeconds -or $null -eq $active.weekly.resetEpochSeconds) {
        throw 'Valid reset text was not converted to countdown timestamps.'
    }

    $errorAccount = $result.accounts[1]
    Assert-Equal $errorAccount.fiveHour.status 'http_error' 'HTTP error classification changed.'
    Assert-Equal $errorAccount.fiveHour.statusCode '401' 'HTTP status code was not parsed.'
    Assert-Equal $errorAccount.weekly.status 'api_error' 'Named API error classification changed.'
    Assert-Equal $errorAccount.weekly.errorName 'rate_limit' 'Named API error was not parsed.'
} finally {
    if ($testDirectory.StartsWith($expectedTempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $testDirectory)) {
        Remove-Item -LiteralPath $testDirectory -Recurse -Force
    }
}

Write-Host 'Usage parser behavior passed with isolated codex-auth fixture data.' -ForegroundColor Green
