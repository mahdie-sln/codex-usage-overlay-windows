$ErrorActionPreference = 'SilentlyContinue'

$installDirectory = $PSScriptRoot
$overlayLauncher = Join-Path $installDirectory 'Start-CodexUsageOverlay.vbs'
$wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$pollMilliseconds = 2000

$createdNew = $false
$watcherMutex = [Threading.Mutex]::new($true, 'Local\CodexUsageOverlay.Watcher', [ref]$createdNew)
if (-not $createdNew) {
    $watcherMutex.Dispose()
    exit 0
}

function Test-CodexDesktopRunning {
    $desktopProcesses = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'")
    foreach ($process in $desktopProcesses) {
        $path = [string]$process.ExecutablePath
        if ($path -like '*\WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe') {
            return $true
        }
    }

    # The packaged desktop app also owns this backend. This fallback survives
    # package updates while excluding ordinary codex.exe copies elsewhere.
    $backendProcesses = @(Get-CimInstance Win32_Process -Filter "Name='codex.exe'")
    foreach ($process in $backendProcesses) {
        $path = [string]$process.ExecutablePath
        if ($path -like '*\AppData\Local\OpenAI\Codex\bin\*\codex.exe') {
            return $true
        }
    }

    return $false
}

try {
    $wasCodexRunning = $false
    while ($true) {
        $isCodexRunning = Test-CodexDesktopRunning
        if ($isCodexRunning -and -not $wasCodexRunning -and
            (Test-Path -LiteralPath $overlayLauncher -PathType Leaf) -and
            (Test-Path -LiteralPath $wscriptPath -PathType Leaf)) {
            Start-Process -FilePath $wscriptPath -ArgumentList ('"{0}"' -f $overlayLauncher) -WindowStyle Hidden
        }

        $wasCodexRunning = $isCodexRunning
        Start-Sleep -Milliseconds $pollMilliseconds
    }
} finally {
    $watcherMutex.ReleaseMutex()
    $watcherMutex.Dispose()
}
