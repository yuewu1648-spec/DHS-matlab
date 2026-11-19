# Verify workspace isolation: two independent session workspaces each get their
# own artifacts, the agent installation folder is never modified at runtime, and
# artifact paths outside the session workspace are rejected.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check_isolation.ps1
#
# Exit code 0 = isolated, 1 = failure.

param(
    [string]$ProjectRoot = ''
)

$ErrorActionPreference = 'Continue'
if ($ProjectRoot -eq '') { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$root = (Resolve-Path $ProjectRoot).Path
$script = Join-Path $root 'bridge\test\isolation.test.mjs'
if (-not (Test-Path $script)) {
    Write-Output "FAIL: $script missing"
    exit 1
}
$out = & node $script 2>&1 | Out-String
Write-Output $out
if ($out -match 'ISOLATION OK') { exit 0 }
exit 1
