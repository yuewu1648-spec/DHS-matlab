# Install (or reinstall) the BioModel-MATLAB DSH bundle in the active profile.
#
# Run from a normal (unrestricted) PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install_bundle.ps1
#
# Steps:
#   1. fix the absolute skills path in bridge/cordis.patch.yml for this checkout
#   2. ensure bridge/node_modules has the dsh-tools dependency
#   3. verify MATLAB is runnable
#   4. print the plugin_manager call that installs the bundle (bundle installation
#      must go through the DSH host: plugin_manager install_bundle)

param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$SkipNpm,
    [string]$MatlabExe = 'C:\Program Files\MATLAB\R2024a\bin\matlab.exe'
)

$ErrorActionPreference = 'Stop'
$bridge = Join-Path $ProjectRoot 'bridge'
$patch = Join-Path $bridge 'cordis.patch.yml'

Write-Output "== 1/4 checkout: $ProjectRoot"

# --- 1. point skill-filesystem at this checkout -----------------------------
$skillsPath = (Join-Path $bridge 'skills') -replace '\\', '/'
$text = Get-Content -Path $patch -Raw -Encoding UTF8
$newText = [regex]::Replace(
    $text,
    "(?ms)(customSkillDirs:\s*\r?\n\s*-\s*)'[^']*'",
    "`${1}'$skillsPath'"
)
if ($newText -ne $text) {
    [System.IO.File]::WriteAllText($patch, $newText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "   updated customSkillDirs -> $skillsPath"
} else {
    Write-Output '   customSkillDirs already current'
}

# --- 2. plugin runtime dependency ------------------------------------------
Write-Output '== 2/4 bridge dependencies'
if ($SkipNpm) {
    Write-Output '   skipped (-SkipNpm)'
} elseif (Test-Path (Join-Path $bridge 'node_modules\@deepseek-ai\dsh-tools')) {
    Write-Output '   @deepseek-ai/dsh-tools present'
} else {
    $cache = Join-Path $ProjectRoot '.tmp\npm-cache'
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    Push-Location $bridge
    try {
        & npm.cmd install --no-audit --no-fund --cache $cache
        if ($LASTEXITCODE -ne 0) { throw "npm install failed ($LASTEXITCODE)" }
    } finally {
        Pop-Location
    }
    Write-Output '   installed @deepseek-ai/dsh-tools'
}

# --- 3. MATLAB smoke test ---------------------------------------------------
Write-Output '== 3/4 MATLAB R2024a'
$matlab = $MatlabExe
if (-not (Test-Path $matlab)) { throw "MATLAB not found at $matlab" }
$code = "addpath('$($ProjectRoot -replace '\\','/')/matlab'); fprintf('matlab %s ok, bma.spec.validate=%d\n', version, exist('bma.spec.validate','file'))"
& $matlab -batch $code 2>&1 | Where-Object { $_ -notmatch 'Unable to load ApplicationService' }
if ($LASTEXITCODE -ne 0) { throw "MATLAB smoke test failed ($LASTEXITCODE)" }

# --- 4. install through DSH -------------------------------------------------
Write-Output '== 4/4 install bundle in DSH'
Write-Output '   Run this in the DSH agent session (needs full access):'
Write-Output ''
Write-Output "   plugin_manager install_bundle { `"target`": `"$bridge`" }"
Write-Output ''
Write-Output '   Then verify:'
Write-Output '   - plugin_manager list_bundles  -> contains @local/dsh-bio-matlab'
Write-Output '   - preset roster contains "MATLAB 生物系统建模" (id bio-matlab)'
Write-Output ''
Write-Output 'Done. If the bundle was already installed, only its live files changed.'
