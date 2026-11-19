# BioModel-MATLAB RPC helper (Windows PowerShell 5.1+ compatible).
#
# Examples:
#   .\scripts\rpc.ps1 -Method server.ping
#   .\scripts\rpc.ps1 -Method test.run -Params '{"filter":"test_io_"}'
#   .\scripts\rpc.ps1 -Method dev.eval -CodeFile .tmp\probe.m -Timeout 120
#   .\scripts\rpc.ps1 -Method spec.validate -ParamsFile .tmp\spec_params.json -Timeout 300
#
# The shared MATLAB server is owned by bridge/lib/server-keeper.mjs. This
# helper never starts MATLAB; if the server is absent it reports
# BMA_SERVER_ABSENT and the caller should retry after a short wait.

param(
    [Parameter(Mandatory = $true)][string]$Method,
    [string]$Params = '',
    [string]$ParamsFile = '',
    [string]$CodeFile = '',
    [int]$Timeout = 240,
    [string]$WorkDir = 'E:\matlab系统建模',
    [switch]$Compact
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $root 'bridge\lib\rpc-cli.mjs'))) {
    $root = $WorkDir
}
$cli = Join-Path $root 'bridge\lib\rpc-cli.mjs'

# PS 5.1 passes native arguments through the console code page; put non-ASCII
# params in a UTF-8 file when possible. Inline JSON should stay ASCII.
$cliArgs = @(
    $cli,
    '--work-dir', $WorkDir,
    '--method', $Method,
    '--timeout', "$Timeout"
)
if ($ParamsFile) {
    $cliArgs += @('--params-file', $ParamsFile)
} elseif ($Params) {
    $cliArgs += @('--params', $Params)
}
if ($CodeFile) {
    $cliArgs += @('--code-file', $CodeFile)
}
if ($Compact) {
    $cliArgs += '--compact'
}
& node @cliArgs
exit $LASTEXITCODE
