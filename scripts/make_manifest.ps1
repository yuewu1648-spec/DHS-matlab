# Generate MANIFEST.sha256 for a release/build of the BioModel-MATLAB agent.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make_manifest.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\make_manifest.ps1 -OutFile MANIFEST.sha256
#
# The manifest pins every shipped source file (MATLAB, bridge, knowledge base,
# spec examples, docs, tests, scripts) by SHA-256, excluding runtime/dev
# directories. `scripts\check_agent.ps1` verifies it, so an installed checkout can
# prove it has not been modified.

param(
    [string]$ProjectRoot = '',
    [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
if ($ProjectRoot -eq '') { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$root = (Resolve-Path $ProjectRoot).Path
if ($OutFile -eq '') { $OutFile = Join-Path $root 'MANIFEST.sha256' }

$excludeDirs = @(
    '\.bma', '\.tmp', '\.qa', '\.git', 'node_modules',
    'tests[\\/]e2e[\\/]artifacts', 'bridge[\\/]node_modules', '__pycache__'
)
$excludeFiles = @('MANIFEST.sha256')

$includeRoots = @(
    'VERSION', 'CHANGELOG.md', 'README.md', 'startup_bma.m',
    'matlab', 'bridge', 'kb', 'spec', 'tests', 'scripts', 'docs'
)

$files = New-Object System.Collections.Generic.List[string]
foreach ($rel in $includeRoots) {
    $p = Join-Path $root $rel
    if (-not (Test-Path $p)) { continue }
    if ((Get-Item $p) -is [System.IO.FileInfo]) {
        $files.Add((Get-Item $p).FullName)
        continue
    }
    Get-ChildItem $p -Recurse -File -Force | ForEach-Object { $files.Add($_.FullName) }
}

$relFiles = @()
foreach ($f in $files) {
    $rel = $f.Substring($root.Length + 1).Replace('\', '/')
    $skip = $false
    foreach ($ex in $excludeDirs) { if ($rel -match $ex) { $skip = $true; break } }
    if (-not $skip) { $relFiles += $rel }
}
$relFiles = $relFiles | Where-Object { $excludeFiles -notcontains $_ } | Sort-Object

$lines = New-Object System.Collections.Generic.List[string]
foreach ($rel in $relFiles) {
    $abs = Join-Path $root ($rel.Replace('/', '\'))
    $hash = (Get-FileHash -Path $abs -Algorithm SHA256).Hash.ToLowerInvariant()
    $lines.Add("$hash  $rel")
}

[System.IO.File]::WriteAllText($OutFile, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
Write-Output ("MANIFEST written: {0} files, agent version {1}, sha256 {2}" -f $lines.Count, $version,
    (Get-FileHash -Path $OutFile -Algorithm SHA256).Hash.ToLowerInvariant().Substring(0, 16))
Write-Output "file: $OutFile"
