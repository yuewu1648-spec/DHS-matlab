# Run MATLAB batch code in one call (unconfined shell; ~15 s startup).
#
#   .\scripts\matlab_batch.ps1 -Code "disp(version)"
#   .\scripts\matlab_batch.ps1 -MFile "matlab\tests\test_spec_validate.m"
#   .\scripts\matlab_batch.ps1 -Filter "test_spec_"          # runs run_all_tests
#   .\scripts\matlab_batch.ps1 -Filter "test_io_" -TimeoutSec 1800
#
# Chinese output is captured through MATLAB's -logfile (UTF-8) instead of the
# console code page, so test logs stay readable.

param(
    [string]$Code = '',
    [string]$MFile = '',
    [string]$Filter = '',
    [string]$ProjectRoot = 'E:\matlab系统建模',
    [int]$TimeoutSec = 1800,
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'
$matlab = 'C:\Program Files\MATLAB\R2024a\bin\matlab.exe'
if (-not (Test-Path $matlab)) { throw "MATLAB not found at $matlab" }
$rootFwd = $ProjectRoot -replace '\\', '/'
$mlFwd = "$rootFwd/matlab"

if ($LogFile -eq '') {
    $logDir = Join-Path $ProjectRoot '.tmp'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $LogFile = Join-Path $logDir ("matlab-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
}

$prelude = "addpath('$mlFwd'); addpath('$mlFwd/tests'); "
if ($MFile -ne '') {
    $mFwd = (Resolve-Path $MFile).Path -replace '\\', '/'
    $runCode = $prelude + "run('$mFwd');"
} elseif ($Filter -ne '') {
    $runCode = $prelude + "ok = run_all_tests('Filter', '$Filter'); if ~ok, exit(1); end"
} else {
    $runCode = $prelude + $Code
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $matlab
$psi.Arguments = '-batch "' + ($runCode -replace '"', '\"') + '" -logfile "' + ($LogFile -replace '\\', '/') + '"'
$psi.WorkingDirectory = $ProjectRoot
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
# Under the DSH file sandbox %APPDATA% is not writable; without redirected
# pref/temp/home MATLAB stalls at startup. Use a per-run temp area.
$sandboxRoot = Join-Path $env:TEMP ('bma-matlab-' + [guid]::NewGuid().ToString('N'))
$prefDir = Join-Path $sandboxRoot 'matlab_pref'
$tempDir = Join-Path $sandboxRoot 'temp'
$homeDir = Join-Path $sandboxRoot 'home'
New-Item -ItemType Directory -Force -Path $prefDir, $tempDir, $homeDir | Out-Null
$psi.EnvironmentVariables['MATLAB_PREFDIR'] = $prefDir
$psi.EnvironmentVariables['TMP'] = $tempDir
$psi.EnvironmentVariables['TEMP'] = $tempDir
$psi.EnvironmentVariables['HOME'] = $homeDir
$proc = [System.Diagnostics.Process]::Start($psi)
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    try { $proc.Kill() } catch {}
    Write-Output "MATLAB TIMEOUT after ${TimeoutSec}s"
    exit 124
}
$exit = $proc.ExitCode
if (Test-Path $LogFile) {
    Get-Content -Path $LogFile -Encoding Default | Where-Object { $_ -notmatch 'Unable to load ApplicationService' }
}
if ($stdout.Trim() -ne '') { Write-Output $stdout }
if ($stderr.Trim() -ne '' -and $exit -ne 0) { Write-Output $stderr }
Write-Output "MATLAB exit=$exit log=$LogFile"
Remove-Item $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
exit $exit
