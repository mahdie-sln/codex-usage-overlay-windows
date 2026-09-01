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

$archivePath = Join-Path $outputRoot 'CodexUsageOverlay-Windows.zip'
$checksumPath = "$archivePath.sha256"
$null = New-Item -ItemType Directory -Path $outputRoot -Force
foreach ($path in @($archivePath, $checksumPath)) {
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force
    }
}

$sourceFiles = [Collections.Generic.List[IO.FileInfo]]::new()
foreach ($relativePath in $packageItems) {
    $sourcePath = Join-Path $repositoryRoot $relativePath
    if (Test-Path -LiteralPath $sourcePath -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $sourcePath -Recurse -File)) {
            $sourceFiles.Add($file)
        }
    } else {
        $sourceFiles.Add((Get-Item -LiteralPath $sourcePath))
    }
}

Add-Type -AssemblyName System.IO.Compression
$archiveStream = $null
$archive = $null
try {
    $archiveStream = New-Object IO.FileStream(
        $archivePath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    $archive = New-Object IO.Compression.ZipArchive(
        $archiveStream,
        [IO.Compression.ZipArchiveMode]::Create,
        $false
    )
    $fixedTimestamp = [DateTimeOffset]::Parse(
        '2000-01-01T00:00:00Z',
        [Globalization.CultureInfo]::InvariantCulture
    )
    foreach ($file in @($sourceFiles | Sort-Object FullName)) {
        $entryName = $file.FullName.Substring($repositoryRoot.Length + 1).Replace('\', '/')
        $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $fixedTimestamp
        $inputStream = $null
        $entryStream = $null
        try {
            $inputStream = $file.OpenRead()
            $entryStream = $entry.Open()
            $inputStream.CopyTo($entryStream)
        } finally {
            if ($null -ne $entryStream) { $entryStream.Dispose() }
            if ($null -ne $inputStream) { $inputStream.Dispose() }
        }
    }
} finally {
    if ($null -ne $archive) { $archive.Dispose() }
    if ($null -ne $archiveStream) { $archiveStream.Dispose() }
}

$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToUpperInvariant()
"$hash  $([IO.Path]::GetFileName($archivePath))" | Set-Content -LiteralPath $checksumPath -Encoding ASCII

Write-Host "Release archive: $archivePath" -ForegroundColor Green
Write-Host "SHA-256: $hash"
