# pde_watchdog.ps1 — hard wall-clock budget for a 2D/3D native PDE solve.
#
# Why this exists: MATLAB's solvepde exposes neither a callback nor a node-wise
# restart (setInitialConditions accepts only a scalar or a length-N vector), so an
# in-process deadline cannot be enforced: a pathological nonlinear solve spins
# inside the integrator and never returns. This wrapper runs the solve in a child
# MATLAB, waits at most -DeadlineSeconds, force-kills the child on overrun and
# reports whether the result file was produced.
#
# Usage:
#   .\scripts\pde_watchdog.ps1 -SpecPath <spec.json> [-OptionsJson '{"n":7,"time_end":150}'] `
#        [-RunDir <dir>] [-WorkDirPath <dir>] [-DeadlineSeconds 120] [-MatlabPath <matlab.exe>]
#
# Output (stdout, last line is a JSON object):
#   {"status":"completed|timeout|error","elapsed_s":..,"result_mat":..,"log":..}
param(
    [Parameter(Mandatory = $true)][string]$SpecPath,
    [string]$OptionsJson = '{}',
    [string]$OptionsFile = '',
    [string]$RunDir = '',
    [string]$WorkDirPath = '',
    [int]$DeadlineSeconds = 120,
    [string]$MatlabPath = ''
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ($WorkDirPath -eq '') { $WorkDirPath = (Get-Location).Path }
if ($RunDir -eq '') { $RunDir = Join-Path $WorkDirPath ('.bma\pde_watchdog_' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
if ($MatlabPath -eq '') {
    $cand = @('C:\Program Files\MATLAB\R2024a\bin\matlab.exe') | Where-Object { Test-Path $_ }
    if (-not $cand) {
        $cand = Get-ChildItem 'C:\Program Files\MATLAB' -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'bin\matlab.exe' } |
            Where-Object { Test-Path $_ } | Select-Object -First 1
    }
    if (-not $cand) { throw 'MATLAB executable not found; pass -MatlabPath.' }
    $MatlabPath = $cand
}
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
$driverDir = Join-Path $env:TEMP ('pde_watchdog_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $driverDir | Out-Null
$resultMat = Join-Path $RunDir 'guarded_result.mat'
$logPath = Join-Path $RunDir 'guarded_stdout.log'
# Start-Process redirection to a non-ASCII path fails silently on this platform,
# so the child writes to an ASCII temp log which is copied back afterwards.
$logTmp = Join-Path $env:TEMP ('pde_guarded_' + [guid]::NewGuid().ToString('N') + '.log')
$specAbs = (Resolve-Path $SpecPath).Path

# The child driver is UTF-8 and carries the (possibly non-ASCII) paths inside the file.
$lines = @(
    "addpath(fullfile('$repoRoot','matlab'));",
    $(if ($OptionsFile -ne "") {
        "opts = jsondecode(fileread('$((Resolve-Path $OptionsFile).Path)'));"
      } else {
        "opts = jsondecode('$($OptionsJson -replace "'", "''")');"
      }),
    "opts.run_dir = '$RunDir';",
    "opts.work_dir = '$WorkDirPath';",
    "res = bma.pde.simulate('$specAbs', opts);",
    "save('-v7', '$resultMat', 'res');",
    "fprintf('WATCHDOG_CHILD_DONE\n');"
)
$driver = Join-Path $driverDir 'pde_guarded_driver.m'
[System.IO.File]::WriteAllLines($driver, $lines, (New-Object System.Text.UTF8Encoding($false)))

$sw = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $MatlabPath `
    -ArgumentList @('-nosplash', '-sd', $driverDir, '-batch', 'pde_guarded_driver') `
    -RedirectStandardOutput $logTmp -RedirectStandardError ($logTmp + '.err') `
    -WindowStyle Hidden -PassThru
$finished = $p.WaitForExit($DeadlineSeconds * 1000)
$sw.Stop()
$status = 'completed'
if (-not $finished) {
    $status = 'timeout'
    try { & taskkill /PID $p.Id /T /F 2>&1 | Out-Null } catch { }
}
try { Copy-Item $logTmp $logPath -Force } catch { }
try { if (Test-Path ($logTmp + '.err')) { Copy-Item ($logTmp + '.err') ($logPath + '.err') -Force } } catch { }
if ($status -eq 'completed' -and -not (Test-Path $resultMat)) {
    $status = 'error'
    if ((Test-Path $logTmp) -and ((Get-Item $logTmp).Length -lt 4000)) { Get-Content $logTmp -Tail 20 | Write-Output }
    if (Test-Path ($logTmp + '.err')) { Get-Content ($logTmp + '.err') -Tail 20 | Write-Output }
}
try { Remove-Item $driverDir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
$summary = [ordered]@{
    status     = $status
    elapsed_s  = [math]::Round($sw.Elapsed.TotalSeconds, 2)
    deadline_s = $DeadlineSeconds
    result_mat = $(if (Test-Path $resultMat) { $resultMat } else { '' })
    log        = $logPath
}
$summary | ConvertTo-Json -Compress
