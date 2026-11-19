# Controlled version bump for the BioModel-MATLAB agent.
#
# Use this in a maintenance window:
#   1. make code/doc changes
#   2. .\scripts\update_agent.ps1 -Version 0.2.0 -Note "新增 ... " -Seal
#   3. in DSH: plugin_manager remove_bundle @local/dsh-bio-matlab,
#              then plugin_manager install_bundle E:\matlab系统建模\bridge
#   4. .\scripts\check_agent.ps1  +  .\scripts\check_isolation.ps1
#
# The script never touches the DSH profile itself: bundle reinstalling is done by
# plugin_manager so the host owns profile state.

param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Note = '',
    [string]$ProjectRoot = '',
    [switch]$Seal
)

$ErrorActionPreference = 'Stop'
if ($ProjectRoot -eq '') { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$root = (Resolve-Path $ProjectRoot).Path

if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must be SemVer x.y.z, got: $Version" }

# require write access (maintenance window)
$probe = Join-Path $root ('.bma-write-probe-' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    [System.IO.File]::WriteAllText($probe, 'probe')
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
} catch {
    throw 'Agent folder is not writable; cannot bump the version.'
}

$oldVersion = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
if ($Version -eq $oldVersion) { throw "Version already $Version; nothing to bump." }

function Compare-SemVer([string]$a, [string]$b) {
    $pa = $a.Split('.') | ForEach-Object { [int]$_ }
    $pb = $b.Split('.') | ForEach-Object { [int]$_ }
    for ($i = 0; $i -lt 3; $i++) {
        if ($pa[$i] -gt $pb[$i]) { return 1 }
        if ($pa[$i] -lt $pb[$i]) { return -1 }
    }
    return 0
}
if ((Compare-SemVer $Version $oldVersion) -le 0) { throw "New version must be greater than $oldVersion" }

Write-Output "bumping agent version: $oldVersion -> $Version"

# 1) VERSION
[System.IO.File]::WriteAllText((Join-Path $root 'VERSION'), "$Version`n", (New-Object System.Text.UTF8Encoding($false)))

# 2) bridge/package.json version
$pkgPath = Join-Path $root 'bridge\package.json'
$pkgText = Get-Content $pkgPath -Raw -Encoding UTF8
$newPkgText = [regex]::Replace($pkgText, '("version"\s*:\s*")[^"]*(")', "`${1}$Version`${2}", 1)
[System.IO.File]::WriteAllText($pkgPath, $newPkgText, (New-Object System.Text.UTF8Encoding($false)))

# 3) CHANGELOG entry
$changelogPath = Join-Path $root 'CHANGELOG.md'
$cl = Get-Content $changelogPath -Raw -Encoding UTF8
$today = (Get-Date).ToString('yyyy-MM-dd')
$entry = "## [$Version] - $today`n`n### Changed`n- $Note`n`n"
# Insert before the first released version section so the newest entry is first.
$marker = "`n## ["
$idx = $cl.IndexOf($marker)
if ($idx -lt 0) { throw 'CHANGELOG has no released-version section' }
$idx = $idx + 1
$cl = $cl.Substring(0, $idx) + $entry + $cl.Substring($idx)
[System.IO.File]::WriteAllText($changelogPath, $cl, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "VERSION, bridge/package.json, CHANGELOG.md updated"

# 4) optional integrity seal
if ($Seal) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\make_manifest.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'make_manifest failed' }
}

Write-Output ''
$bridgePath = Join-Path $root 'bridge'
Write-Output '下一步（DSH 内执行，需要 Full access）：'
Write-Output '  1) plugin_manager remove_bundle  target="@local/dsh-bio-matlab"'
Write-Output ('  2) plugin_manager install_bundle target="{0}"' -f $bridgePath)
Write-Output '  3) powershell -File scripts\check_agent.ps1'
Write-Output '  4) powershell -File scripts\check_isolation.ps1'
Write-Output ''
Write-Output '回滚：把 VERSION/package.json/CHANGELOG 恢复到上一个版本，重新安装 bundle。'
