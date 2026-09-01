[CmdletBinding()]
param(
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repositoryRoot 'dist'
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if (-not $outputRoot.StartsWith(($repositoryRoot + '\'), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must be a child of the repository root.'
}

$packageItems = @(
    'src',
    'docs',
    'Install.ps1',
    'Uninstall.ps1',
    'README.md',
    'LICENSE'
)
foreach ($relativePath in $packageItems) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $relativePath))) {
        throw "Release input is missing: $relativePath"
    }
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$stagingDirectory = Join-Path $tempRoot ("CodexUsageOverlay-Release-{0}" -f [Guid]::NewGuid().ToString('N'))
$stagingDirectory = [IO.Path]::GetFullPath($stagingDirectory)
if (-not $stagingDirectory.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Staging directory escaped the Windows temporary directory.'
}

$archivePath = Join-Path $outputRoot 'CodexUsageOverlay-Windows.zip'
$checksumPath = "$archivePath.sha256"
try {
    $null = New-Item -ItemType Directory -Path $stagingDirectory
    foreach ($relativePath in $packageItems) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot $relativePath) `
            -Destination (Join-Path $stagingDirectory (Split-Path -Leaf $relativePath)) -Recurse
    }

    $null = New-Item -ItemType Directory -Path $outputRoot -Force
    foreach ($path in @($archivePath, $checksumPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    Compress-Archive -Path (Join-Path $stagingDirectory '*') -DestinationPath $archivePath -CompressionLevel Optimal
    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
    "$hash  $([IO.Path]::GetFileName($archivePath))" | Set-Content -LiteralPath $checksumPath -Encoding ASCII
} finally {
    if ($stagingDirectory.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $stagingDirectory)) {
        Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
    }
}

Write-Host "Release archive: $archivePath" -ForegroundColor Green
Write-Host "SHA-256: $hash"
