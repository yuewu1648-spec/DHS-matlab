# Stop stray MATLAB bma server processes and clean their IPC state.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\stop_matlab_servers.ps1
#   ... -WorkDir "E:\matlab系统建模\.tmp\dev-core"   # only one work dir
#   ... -All                                         # every bma.server MATLAB process

param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$WorkDir = '',
    [switch]$All
)

$ErrorActionPreference = 'Continue'
$killed = 0

Write-Output '== scanning MATLAB processes for bma.server.start'
$procs = Get-CimInstance Win32_Process -Filter "Name='MATLAB.exe' OR Name='matlab.exe'" -ErrorAction SilentlyContinue
foreach ($p in $procs) {
    $cmd = [string]$p.CommandLine
    if ($cmd -notmatch 'bma\.server\.start') { continue }
    if (-not $All) {
        if ($WorkDir -ne '') {
            $needle = $WorkDir -replace '\\', '/'
            if (($cmd -notmatch [regex]::Escape($needle))) { continue }
        } else {
            # default: only servers under this project's .bma trees
            if ($cmd -notmatch [regex]::Escape(($ProjectRoot -replace '\\', '/'))) { continue }
        }
    }
    Write-Output "   stopping pid=$($p.ProcessId)"
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ } catch {}
}

Write-Output '== cleaning IPC state'
$roots = @()
if ($WorkDir -ne '') { $roots = @($WorkDir) }
elseif ($All) {
    $roots = @($ProjectRoot) + @(Get-ChildItem (Join-Path $ProjectRoot '.tmp') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
} else {
    $roots = @($ProjectRoot) + @(Get-ChildItem (Join-Path $ProjectRoot '.tmp') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
foreach ($r in $roots) {
    $srv = Join-Path $r '.bma\server'
    if (-not (Test-Path $srv)) { continue }
    Remove-Item (Join-Path $srv 'state.json'), (Join-Path $srv 'keeper.json'), (Join-Path $srv 'spawn.lock') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $srv 'inbox\*'), (Join-Path $srv 'outbox\*'), (Join-Path $srv 'claims\*') -Force -ErrorAction SilentlyContinue
    Write-Output "   cleaned $srv"
}

Write-Output "== done: killed=$killed process(es)"
