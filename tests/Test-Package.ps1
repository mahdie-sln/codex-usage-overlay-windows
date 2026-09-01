$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$failures = [Collections.Generic.List[string]]::new()

function Add-Failure([string]$Message) { $failures.Add($Message) }

$requiredFiles = @(
    '.gitignore', 'LICENSE', 'README.md', 'Install.ps1', 'Uninstall.ps1',
    '.github\SECURITY.md', '.github\CONTRIBUTING.md', '.github\workflows\test.yml',
    '.github\dependabot.yml',
    'src\config.example.json', 'src\CodexUsageOverlay.ps1',
    'src\CodexOverlayWatcher.ps1', 'src\Get-CodexAccounts.ps1',
    'src\Switch-CodexAccount.ps1', 'src\Remove-CodexAccount.ps1',
    'src\Start-CodexAuthLogin.ps1', 'src\Start-CodexUsageOverlay.vbs',
    'src\Start-CodexOverlayWatcher.vbs', 'src\Restart-CodexUsageOverlay.vbs',
    'docs\ARCHITECTURE.md', 'docs\PRIVACY.md', 'docs\THIRD_PARTY_NOTICES.md', 'docs\TESTING.md',
    'docs\CHANGELOG.md',
    'tests\Test-UsageParser.ps1',
    'tools\Build-Release.ps1',
    'docs\images\hero.png', 'docs\images\step-1-download.png',
    'docs\images\step-2-powershell.png', 'docs\images\step-3-install.png',
    'docs\images\step-4-bar.png', 'docs\images\step-5-accounts.png'
)
foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $relativePath) -PathType Leaf)) {
        Add-Failure "Missing required file: $relativePath"
    }
}

$forbiddenGeneratedNames = @(
    'config.json', 'position.json', 'runtime-status.json', 'warning-state.json',
    'install-manifest.json', 'overlay.log', 'preview.log'
)
foreach ($file in @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File)) {
    if ($forbiddenGeneratedNames -contains $file.Name) {
        Add-Failure "Generated/private file is present: $($file.FullName.Substring($repositoryRoot.Length + 1))"
    }
}

$textExtensions = @('.ps1', '.vbs', '.json', '.md', '.txt', '.yml', '.yaml', '.svg')
$textFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File | Where-Object {
    $textExtensions -contains $_.Extension.ToLowerInvariant()
})
$personalPatterns = @(
    @{ Name = 'absolute user profile'; Pattern = '(?i)C:\\Users\\' },
    @{ Name = 'non-example email address'; Pattern = '(?i)\b[A-Z0-9._%+-]+@(?!example\.com\b)[A-Z0-9.-]+\.[A-Z]{2,}\b' },
    @{ Name = 'OpenAI-style API key'; Pattern = '\bsk-[A-Za-z0-9_-]{20,}\b' },
    @{ Name = 'bearer credential'; Pattern = '(?i)Authorization\s*:\s*Bearer\s+\S+' }
)
foreach ($file in $textFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($check in $personalPatterns) {
        if ($content -match $check.Pattern) {
            Add-Failure "$($check.Name) detected in $($file.FullName.Substring($repositoryRoot.Length + 1))"
        }
    }
    if ($content -match '[\u0600-\u06FF]') {
        Add-Failure "Non-English UI/documentation text detected in $($file.FullName.Substring($repositoryRoot.Length + 1))"
    }
}

$powerShellFiles = @(Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File -Filter '*.ps1')
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) {
        Add-Failure "PowerShell syntax error in $($file.Name): $($parseError.Message)"
    }
}

$overlayPath = Join-Path $repositoryRoot 'src\CodexUsageOverlay.ps1'
$overlayLines = Get-Content -LiteralPath $overlayPath
$xamlStart = [Array]::IndexOf($overlayLines, "`$xaml = @'")
$xamlEnd = -1
if ($xamlStart -ge 0) {
    for ($index = $xamlStart + 1; $index -lt $overlayLines.Count; $index++) {
        if ($overlayLines[$index] -eq "'@") { $xamlEnd = $index; break }
    }
}
if ($xamlStart -lt 0 -or $xamlEnd -le $xamlStart) {
    Add-Failure 'Embedded XAML block was not found.'
} else {
    try { $null = [xml](($overlayLines[($xamlStart + 1)..($xamlEnd - 1)]) -join "`n") }
    catch { Add-Failure "Embedded XAML is invalid: $($_.Exception.Message)" }
}

try {
    $config = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\config.example.json') -Raw | ConvertFrom-Json
    if ([bool]$config.apiUsageConsent) { Add-Failure 'Example config must default apiUsageConsent to false.' }
    if (-not [string]::IsNullOrWhiteSpace([string]$config.codexAuthExecutable)) { Add-Failure 'Example config contains a codex-auth path.' }
    if (@($config.accountExpiryDates.PSObject.Properties).Count -ne 0) { Add-Failure 'Example config contains account expiry identifiers.' }
} catch {
    Add-Failure "Example configuration is invalid: $($_.Exception.Message)"
}

$runtimeFiles = @(
    'src\CodexUsageOverlay.ps1', 'src\CodexOverlayWatcher.ps1',
    'src\Get-CodexAccounts.ps1', 'src\Switch-CodexAccount.ps1',
    'src\Remove-CodexAccount.ps1', 'src\Start-CodexAuthLogin.ps1'
)
foreach ($relativePath in $runtimeFiles) {
    $content = Get-Content -LiteralPath (Join-Path $repositoryRoot $relativePath) -Raw
    if ($content -match '(?i)Invoke-WebRequest|Invoke-RestMethod|System\.Net\.Http|WebClient|chatgpt\.com/backend-api') {
        Add-Failure "Direct network implementation detected in $relativePath"
    }
}

$removeContent = Get-Content -LiteralPath (Join-Path $repositoryRoot 'src\Remove-CodexAccount.ps1') -Raw
if ($removeContent -match '(?i)remove\s+--all') {
    Add-Failure 'Account-removal helper contains a bulk remove operation.'
}
if ($removeContent -match '(?i)remove\s+--skip-api\s+\$ExpectedEmail') {
    Add-Failure 'Account-removal helper uses the unsupported remove --skip-api <email> form.'
}
foreach ($requiredMarker in @('ExpectedLabelHash', 'ExpectedEmail', 'remove $ExpectedEmail')) {
    if ($removeContent -notmatch [regex]::Escape($requiredMarker)) {
        Add-Failure "Account-removal helper is missing safe marker: $requiredMarker"
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    throw "Package validation failed with $($failures.Count) issue(s)."
}

Write-Host "Package validation passed: $($requiredFiles.Count) required files, $($powerShellFiles.Count) PowerShell files." -ForegroundColor Green
