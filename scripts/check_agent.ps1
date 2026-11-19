# Verify a BioModel-MATLAB installation: version consistency, integrity
# manifest, DSH bundle installation, MATLAB backend, tool plugin, and
# workspace isolation (artifacts never touch the agent folder, runs stay inside
# their own session workspace).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\check_agent.ps1
#   ... -Quick      # skip the two slower end-to-end checks (MATLAB + isolation)
#
# Exit code 0 = all checks passed, 1 = at least one failure.

param(
    [string]$ProjectRoot = '',
    [switch]$Quick
)

$ErrorActionPreference = 'Continue'
if ($ProjectRoot -eq '') { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$root = (Resolve-Path $ProjectRoot).Path
$fail = 0
$checks = New-Object System.Collections.Generic.List[object]

function Add-Result([string]$name, [bool]$ok, [string]$detail) {
    $script:checks.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail })
    if ($ok) { Write-Output ("[PASS] {0}: {1}" -f $name, $detail) }
    else { Write-Output ("[FAIL] {0}: {1}" -f $name, $detail); $script:fail++ }
}

Write-Output '== BioModel-MATLAB check_agent =='
Write-Output "root: $root"

# --- 1. version -------------------------------------------------------------
$version = ''
try { $version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim() } catch {}
Add-Result 'VERSION file' ($version -match '^\d+\.\d+\.\d+') "VERSION=$version"

$pkgVersion = ''
try {
    $pkg = Get-Content (Join-Path $root 'bridge\package.json') -Raw | ConvertFrom-Json
    $pkgVersion = $pkg.version
} catch {}
Add-Result 'bundle version == agent version' ($pkgVersion -eq $version) "package.json=$pkgVersion VERSION=$version"

# --- 2. integrity manifest --------------------------------------------------
$manifest = Join-Path $root 'MANIFEST.sha256'
if (-not (Test-Path $manifest)) {
    Add-Result 'MANIFEST.sha256' $false 'missing (run scripts\make_manifest.ps1 to seal a release)'
} else {
    $bad = 0
    $missing = 0
    $count = 0
    foreach ($line in (Get-Content $manifest -Encoding UTF8)) {
        if ($line.Trim() -eq '') { continue }
        $parts = $line -split '  ', 2
        if ($parts.Count -ne 2) { continue }
        $expected = $parts[0]
        $rel = $parts[1]
        $abs = Join-Path $root ($rel.Replace('/', '\'))
        if (-not (Test-Path $abs)) { $missing++; continue }
        $actual = (Get-FileHash -Path $abs -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { $bad++; if ($bad -le 5) { Write-Output "       modified: $rel" } }
        $count++
    }
    Add-Result 'integrity manifest' (($bad -eq 0) -and ($missing -eq 0)) "checked=$count modified=$bad missing=$missing"
}

# --- 3. DSH bundle installation --------------------------------------------
$profileDir = ''
if ($env:DSH_HOME) { $profileDir = Join-Path $env:DSH_HOME 'profiles\desktop' }
elseif (Test-Path (Join-Path $env:USERPROFILE '.dsh\profiles\desktop')) { $profileDir = Join-Path $env:USERPROFILE '.dsh\profiles\desktop' }
if ($profileDir -eq '' -or -not (Test-Path (Join-Path $profileDir 'package.json'))) {
    Add-Result 'DSH bundle installed' $false 'desktop profile package.json not found'
} else {
    $profile = Get-Content (Join-Path $profileDir 'package.json') -Raw | ConvertFrom-Json
    $dep = $profile.dependencies.'@local/dsh-bio-matlab'
    $inBundles = @($profile.dsh.profile.bundles) -contains '@local/dsh-bio-matlab'
    $linked = Test-Path (Join-Path $profileDir 'node_modules\@local\dsh-bio-matlab')
    Add-Result 'DSH bundle installed' (($null -ne $dep) -and $inBundles -and $linked) "dependency=$dep bundles=$inBundles link=$linked"
}

# helper: environment for a sandboxed MATLAB start (writable pref/temp/home)
function New-MatlabEnv([string]$dir) {
    $prefDir = Join-Path $dir 'matlab_pref'
    $tempDir = Join-Path $dir 'temp'
    $homeDir = Join-Path $dir 'home'
    New-Item -ItemType Directory -Force -Path $prefDir, $tempDir, $homeDir | Out-Null
    return @{ MATLAB_PREFDIR = $prefDir; TMP = $tempDir; TEMP = $tempDir; HOME = $homeDir }
}

# --- 4. MATLAB backend ------------------------------------------------------
$matlab = 'C:\Program Files\MATLAB\R2024a\bin\matlab.exe'
if (-not (Test-Path $matlab)) {
    Add-Result 'MATLAB backend' $false "MATLAB not found at $matlab"
} elseif ($Quick) {
    Write-Output '[SKIP] MATLAB backend smoke (-Quick)'
} else {
    $tmpCwd = Join-Path $env:TEMP ('bma-check-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmpCwd | Out-Null
    $envs = New-MatlabEnv $tmpCwd
    $code = "addpath('$($root -replace '\\','/')/matlab'); v=bma.version(); fprintf('AGENT_VERSION=%s\n', v.agent_version); fprintf('BUNDLE_VERSION=%s\n', v.bundle_version); fprintf('MATLAB_VERSION=%s\n', v.matlab_version);"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $matlab
    $psi.Arguments = '-batch "' + ($code -replace '"', '\"') + '"'
    $psi.WorkingDirectory = $tmpCwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($k in $envs.Keys) { $psi.EnvironmentVariables[$k] = $envs[$k] }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    if (-not $proc.WaitForExit(600000)) {
        try { $proc.Kill() } catch {}
        Add-Result 'MATLAB backend' $false 'timeout'
    } else {
        $agentLine = ($stdout -split "`n" | Where-Object { $_ -like 'AGENT_VERSION=*' } | Select-Object -First 1)
        $ok = ($proc.ExitCode -eq 0) -and ($agentLine -ne $null)
        Add-Result 'MATLAB backend' $ok "exit=$($proc.ExitCode) $($agentLine.Trim())"
        if (-not $ok -and $stderr.Trim() -ne '') { Write-Output "       stderr: $($stderr.Substring(0, [Math]::Min(500, $stderr.Length)))" }
    }
    Remove-Item $tmpCwd -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 5. tool plugin smoke (Node + MATLAB, writes only to a temp workspace) --
$smokeWork = Join-Path $env:TEMP ('bma-plugin-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $smokeWork | Out-Null
$nodeExe = 'node'
$smokeScript = Join-Path $root 'bridge\test\plugin-smoke.mjs'
if (-not (Test-Path $smokeScript)) {
    Add-Result 'tool plugin smoke' $false 'bridge/test/plugin-smoke.mjs missing'
} else {
    $out = & $nodeExe $smokeScript $smokeWork 2>&1 | Out-String
    $ok = $out -match 'SMOKE OK'
    if ($ok) {
        $detail = 'registered tools + MATLAB backend + spec validate'
    } else {
        $detail = (($out -split "`n" | Select-Object -Last 5) -join ' | ')
    }
    Add-Result 'tool plugin smoke' $ok $detail
}
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'scripts\stop_matlab_servers.ps1') -WorkDir $smokeWork 2>&1 | Out-Null
Remove-Item $smokeWork -Recurse -Force -ErrorAction SilentlyContinue

# --- 6. workspace isolation -------------------------------------------------
$isolationScript = Join-Path $root 'bridge\test\isolation.test.mjs'
if (-not (Test-Path $isolationScript)) {
    Add-Result 'workspace isolation' $false 'bridge/test/isolation.test.mjs missing'
} elseif ($Quick) {
    Write-Output '[SKIP] workspace isolation (-Quick)'
} else {
    $out = & $nodeExe $isolationScript 2>&1 | Out-String
    $ok = $out -match 'ISOLATION OK'
    if ($ok) {
        $detail = 'two workspaces isolated; agent folder untouched; escape rejected'
    } else {
        $detail = (($out -split "`n" | Where-Object { $_ -match 'FAIL|ESCAPE|modified' } | Select-Object -First 6) -join ' | ')
        if ($detail -eq '') { $detail = (($out -split "`n" | Select-Object -Last 5) -join ' | ') }
    }
    Add-Result 'workspace isolation' $ok $detail
}

# --- summary ----------------------------------------------------------------
$passed = @($checks | Where-Object Ok).Count
Write-Output ''
Write-Output ("== {0}/{1} checks passed, {2} failed ==" -f $passed, $checks.Count, $fail)
if ($fail -gt 0) { exit 1 }
exit 0
