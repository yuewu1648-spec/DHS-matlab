# tool_layer_e2e.ps1
# =========================================================================
# Tool-layer end-to-end acceptance test for BioModel-MATLAB.
#
# Calls EVERY bma_* tool equivalent directly through the shared file-based
# MATLAB JSON-RPC (bridge/lib/rpc-cli.mjs), i.e. the same methods the DSH
# plugin exposes to the agent, and asserts the documented result contracts and
# persisted artifacts (docs/DESIGN.md sections 4, 5, 7, 10).
#
# This is the fallback acceptance path required by the task when DeepSeek
# credentials/quota are unavailable for the headless agent E2E; it is also the
# fast regression suite used after any module change.
#
# Usage (Windows PowerShell 5.1):
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/e2e/tool_layer_e2e.ps1 `
#       -WorkDir "E:\matlab系统建模" -StartServer
#
# Parameters:
#   -WorkDir      work directory shared with the MATLAB RPC server (default: project root)
#   -ProjectRoot  repository root (default: parent of tests/)
#   -StartServer  start a detached `matlab -batch` server when none is alive
#   -StopServer   stop the server at the end (only if we started it or explicitly asked)
#   -CallTimeoutMs per-RPC timeout (default 240000)
#   -FailFast     abort on the first failed check
#   -OutDir       artifact directory (default tests/e2e/artifacts/tool-layer-<timestamp>)
#
# Exit codes: 0 = all checks passed, 1 = one or more checks failed,
#             3 = MATLAB RPC precondition not met (server not running / not startable).
#
# Idempotent: every run gets a fresh run_id and artifact directory; rerunning
# never deletes or overwrites previous artifacts. Does not modify the profile.
# =========================================================================
[CmdletBinding()]
param(
    [string]$WorkDir = 'E:\matlab系统建模',
    [string]$ProjectRoot = '',
    [switch]$StartServer,
    [switch]$StopServer,
    [int]$CallTimeoutMs = 240000,
    [ValidateSet('auto', 'file', 'cli')]
    [string]$Transport = 'auto',
    [switch]$FailFast,
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $ProjectRoot) {
    $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$WorkDir = (Resolve-Path -LiteralPath $WorkDir).Path
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutDir) {
    $OutDir = Join-Path $ProjectRoot "tests\e2e\artifacts\tool-layer-$stamp"
}
New-Item -ItemType Directory -Force -Path $OutDir, (Join-Path $OutDir 'rpc'), (Join-Path $OutDir 'params') | Out-Null
$logFile = Join-Path $OutDir 'tool_layer_e2e.log'
$script:logLines = New-Object System.Collections.Generic.List[string]
$script:results = New-Object System.Collections.Generic.List[object]
$script:failures = 0
$script:rpcSeq = 0

$rpcCli = Join-Path $ProjectRoot 'bridge\lib\rpc-cli.mjs'
$stateFile = Join-Path $WorkDir '.bma\server\state.json'
$serverLog = Join-Path $WorkDir '.bma\server\server.log'
$matlabExe = if ($env:BMA_MATLAB_EXE) { $env:BMA_MATLAB_EXE } else {
    'C:\Program Files\MATLAB\R2024a\bin\matlab.exe'
}
$serverToken = "qa-tool-layer-$stamp"
$serverPid = $null
$startedByUs = $false

# ---------------------------------------------------------------------------
function Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    $script:logLines.Add($line)
}

function Save-Log {
    $script:logLines | Set-Content -LiteralPath $logFile -Encoding UTF8
}

function Check([string]$name, [scriptblock]$body) {
    try {
        $detail = & $body
        $script:results.Add([pscustomobject]@{ name = $name; ok = $true; detail = "$detail" })
        Log ("PASS  {0} {1}" -f $name, $detail)
    } catch {
        $script:failures++
        $script:results.Add([pscustomobject]@{ name = $name; ok = $false; detail = $_.Exception.Message })
        Log ("FAIL  {0} :: {1}" -f $name, $_.Exception.Message)
        if ($FailFast) { Save-Log; throw }
    }
}

function Assert-True([bool]$cond, [string]$msg) {
    if (-not $cond) { throw $msg }
}

function Get-ServerState {
    if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
    try {
        return (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-ServerAlive {
    # Liveness = server PID exists. A stale heartbeat is expected while the
    # single-threaded MATLAB server is executing a long request, so the
    # heartbeat timestamp must not be used as a liveness signal here.
    $st = Get-ServerState
    if ($null -eq $st -or $null -eq $st.pid) { return $false }
    return ($null -ne (Get-Process -Id ([int]$st.pid) -ErrorAction SilentlyContinue))
}

function Resolve-Transport {
    # auto: use the documented file protocol; it works in every session.
    # cli:  additionally exercises bridge/lib/rpc-cli.mjs (needs process
    #       visibility / a keeper-owned server).
    if ($Transport -ne 'auto') { return $Transport }
    return 'file'
}

function Invoke-RpcFile([string]$method, $paramsObj) {
    $st = Get-ServerState
    if ($null -eq $st -or -not $st.token) { throw 'shared server state.json/token missing' }
    $script:rpcSeq++
    $seq = '{0:d3}' -f $script:rpcSeq
    $safe = $method -replace '[^A-Za-z0-9_.-]', '_'
    $id = 'qa-e2e-' + $stamp + '-' + $seq
    $request = @{
        schema  = 'bma.rpc.v1'
        id      = $id
        token   = "$($st.token)"
        method  = $method
        params  = $paramsObj
        work_dir = $WorkDir
        timeout_s = [int][math]::Ceiling($CallTimeoutMs / 1000.0)
    }
    $reqJson = $request | ConvertTo-Json -Depth 40
    $srv = Join-Path $WorkDir '.bma\server'
    $tmp = Join-Path $srv ('inbox\' + $id + '.tmp')
    $dst = Join-Path $srv ('inbox\' + $id + '.json')
    # UTF-8 without BOM: MATLAB jsondecode rejects a leading BOM.
    [System.IO.File]::WriteAllText($tmp, $reqJson, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::Move($tmp, $dst)
    $respPath = Join-Path $srv ('outbox\' + $id + '.json')
    $copied = Join-Path (Join-Path $OutDir 'rpc') ("$seq-$safe.response.json")
    $deadline = (Get-Date).AddMilliseconds($CallTimeoutMs)
    $raw = $null
    $serverGone = $false
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $respPath) {
            $raw = Get-Content -LiteralPath $respPath -Raw -ErrorAction SilentlyContinue
            if ($raw -and $raw.Trim().Length -gt 2) { break }
        }
        Start-Sleep -Milliseconds 200
        # MATLAB is single-threaded: a long fit/model-selection call cannot
        # refresh state.json, so a stale heartbeat is NOT a failure. Only a
        # provably absent server PID aborts the wait.
        $st2 = Get-ServerState
        if ($null -eq $st2 -or $null -eq $st2.pid) {
            $serverGone = $true; break
        }
        if ($null -eq (Get-Process -Id ([int]$st2.pid) -ErrorAction SilentlyContinue)) {
            $serverGone = $true; break
        }
    }
    if (-not $raw) {
        if ($serverGone) { throw "RPC $method aborted: MATLAB server process is gone" }
        throw "RPC $method timed out after $CallTimeoutMs ms (server may still be busy)"
    }
    Set-Content -LiteralPath $copied -Value $raw -Encoding UTF8
    $resp = $raw | ConvertFrom-Json
    if (-not $resp.ok) {
        $code = if ($resp.error) { $resp.error.code } else { 'UNKNOWN' }
        $msg = if ($resp.error) { $resp.error.message } else { 'no message' }
        throw "RPC $method returned ok=false ($code): $msg"
    }
    Log ("rpc {0} {1} [file] -> ok" -f $seq, $method)
    return $resp.result
}

function Wait-ServerReady([int]$timeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-ServerAlive) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Start-MatlabServer {
    Log "starting detached MATLAB RPC server (matlab -batch) ..."
    Assert-True (Test-Path -LiteralPath $matlabExe) "MATLAB executable not found: $matlabExe"
    $matlabDir = Join-Path $ProjectRoot 'matlab'
    $cmd = "addpath('$matlabDir'); bma.server.start('$WorkDir', '$serverToken', struct('maxIdleSeconds', 0))"
    $stdout = Join-Path $OutDir 'matlab-server-stdout.log'
    $stderr = Join-Path $OutDir 'matlab-server-stderr.log'
    # Under the DSH file sandbox %APPDATA% is read-only; MATLAB aborts at
    # startup with "failed to load settings errors_warnings plugin" unless
    # pref/temp/home are redirected into the writable workspace (same fix as
    # scripts/matlab_batch.ps1 and the production bridge).
    $envRoot = Join-Path $OutDir 'matlab-env'
    $prefDir = Join-Path $envRoot 'matlab_pref'
    $tempDir = Join-Path $envRoot 'temp'
    $homeDir = Join-Path $envRoot 'home'
    New-Item -ItemType Directory -Force -Path $prefDir, $tempDir, $homeDir | Out-Null
    $template = Join-Path $ProjectRoot '.tmp\matlab_pref_template'
    if ((Test-Path -LiteralPath $template) -and -not (Get-ChildItem -LiteralPath $prefDir -Force -ErrorAction SilentlyContinue)) {
        Copy-Item -Path (Join-Path $template '*') -Destination $prefDir -Recurse -Force
    }
    $oldEnv = @{}
    foreach ($k in @('MATLAB_PREFDIR', 'TMP', 'TEMP', 'HOME')) {
        $oldEnv[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
    }
    $newEnv = @{ MATLAB_PREFDIR = $prefDir; TMP = $tempDir; TEMP = $tempDir; HOME = $homeDir }
    foreach ($k in $newEnv.Keys) {
        [Environment]::SetEnvironmentVariable($k, $newEnv[$k], 'Process')
    }
    try {
        # Use ProcessStartInfo rather than Start-Process: MATLAB's -batch code
        # contains spaces/semicolons, and Start-Process does not quote the
        # argument reliably. -logfile captures stdout without a pipe that the
        # sandbox could block.
        $argLine = '-batch "' + ($cmd -replace '"', '\"') + '" -logfile "' + ($stdout -replace '\\', '/') + '"'
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $matlabExe
        $psi.Arguments = $argLine
        $psi.WorkingDirectory = $ProjectRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $true
        foreach ($k in $newEnv.Keys) {
            $psi.EnvironmentVariables[$k] = $newEnv[$k]
        }
        $p = [System.Diagnostics.Process]::Start($psi)
        $script:serverProcess = $p
        $script:serverErrorTask = $p.StandardError.ReadToEndAsync()
    } finally {
        foreach ($k in $oldEnv.Keys) {
            [Environment]::SetEnvironmentVariable($k, $oldEnv[$k], 'Process')
        }
    }
    $script:serverPid = $p.Id
    $script:startedByUs = $true
    Log "MATLAB process started (pid $($p.Id)); waiting for heartbeat ..."
    if (-not (Wait-ServerReady 240)) {
        if (Test-Path -LiteralPath $stderr) {
            $tail = (Get-Content -LiteralPath $stderr -Tail 30) -join "`n"
            Log "server stderr tail:`n$tail"
        }
        throw "MATLAB RPC server did not become ready within 240 s"
    }
    Log "MATLAB RPC server ready"
}

function Rpc([string]$method, $paramsObj) {
    if ($script:transport -eq 'file') {
        return Invoke-RpcFile $method $paramsObj
    }
    $script:rpcSeq++
    $seq = '{0:d3}' -f $script:rpcSeq
    $safe = $method -replace '[^A-Za-z0-9_.-]', '_'
    $paramsFile = Join-Path (Join-Path $OutDir 'params') ("$seq-$safe.json")
    if ($null -eq $paramsObj) { $paramsObj = @{} }
    ($paramsObj | ConvertTo-Json -Depth 40) | Set-Content -LiteralPath $paramsFile -Encoding UTF8
    $stdout = Join-Path $OutDir "rpc\$seq-$safe.out.json"
    $stderr = Join-Path (Join-Path $OutDir 'rpc') ("$seq-$safe.err.txt")
    $elapsed = Measure-Command {
        & node $rpcCli --work-dir $WorkDir --method $method --params-file $paramsFile `
            --timeout ([int][math]::Ceiling($CallTimeoutMs / 1000.0)) --compact 1> $stdout 2> $stderr
        $script:lastExit = $LASTEXITCODE
    }
    $raw = Get-Content -LiteralPath $stdout -Raw -ErrorAction SilentlyContinue
    if ($script:lastExit -ne 0) {
        $err = Get-Content -LiteralPath $stderr -Raw -ErrorAction SilentlyContinue
        throw "RPC $method failed (exit $($script:lastExit)): $err"
    }
    if (-not $raw) { throw "RPC $method produced no output" }
    try {
        $resp = $raw | ConvertFrom-Json
    } catch {
        throw "RPC $method returned invalid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $resp -or -not $resp.ok) {
        $code = if ($resp.error) { $resp.error.code } elseif ($resp.code) { $resp.code } else { 'UNKNOWN' }
        $m = if ($resp.error) { $resp.error.message } elseif ($resp.message) { $resp.message } else { 'no message' }
        throw "RPC $method returned ok=false ($code): $m"
    }
    Log ("rpc {0} {1} [cli] -> {2:n0} ms" -f $seq, $method, $elapsed.TotalMilliseconds)
    return $resp.result
}

function Get-RelPath([string]$base, [string]$rel) {
    if ([System.IO.Path]::IsPathRooted($rel)) { return $rel }
    return (Join-Path $base ($rel -replace '/', '\'))
}

function Assert-File([string]$base, $rel, [string]$what) {
    Assert-True ($null -ne $rel -and "$rel".Length -gt 0) "$what path is empty"
    $p = Get-RelPath $base "$rel"
    if (Test-Path -LiteralPath $p) { return $p }
    # Some modules return artifact paths relative to the project root instead
    # of work_dir (contract deviation tracked in ACCEPTANCE); accept either.
    $p2 = Get-RelPath $ProjectRoot "$rel"
    Assert-True (Test-Path -LiteralPath $p2) "$what does not exist (work_dir: $p ; project_root: $p2)"
    return $p2
}

function Assert-Array($value, [string]$what) {
    Assert-True ($null -ne $value) "$what is null"
    $arr = @($value)
    Assert-True ($arr.Count -gt 0) "$what is empty"
    return $arr.Count
}

function Test-FactCoverage($expectations, $numbers, [double]$threshold) {
    $checked = 0; $found = 0; $missing = @()
    foreach ($fact in @($expectations.facts)) {
        if ($null -eq $fact.value) { continue }
        $roles = @('parameter', 'initial', 'observation', 'derived')
        if ($fact.role -and ($roles -notcontains $fact.role)) { continue }
        $tv = [double]$fact.value
        $tol = 0.02 * [math]::Max([math]::Abs($tv), 1.0)
        if ($fact.tolerance) {
            if ($null -ne $fact.tolerance.relative) {
                $tol = [math]::Max($tol, [double]$fact.tolerance.relative * [math]::Abs($tv))
            }
            if ($null -ne $fact.tolerance.absolute) {
                $tol = [math]::Max($tol, [double]$fact.tolerance.absolute)
            }
        }
        $checked++
        $hit = $false
        foreach ($num in @($numbers)) {
            if ($null -eq $num.value) { continue }
            if ([math]::Abs([double]$num.value - $tv) -le $tol) { $hit = $true; break }
        }
        if ($hit) { $found++ } else { $missing += ("" + $fact.id) }
    }
    Assert-True ($checked -ge 6) "expected-facts file has too few numeric facts ($checked)"
    $frac = $found / [double]$checked
    $detail = "{0}/{1} expected values found" -f $found, $checked
    if ($missing.Count -gt 0) { $detail += " (missing: " + ($missing -join ', ') + ")" }
    Assert-True ($frac -ge $threshold) "number extraction coverage too low: $detail"
    return $detail
}

# ===========================================================================
# 0. preconditions
# ===========================================================================
Log "BioModel-MATLAB tool-layer E2E"
Log "project root : $ProjectRoot"
Log "work dir     : $WorkDir"
Log "artifacts    : $OutDir"
Assert-True (Test-Path -LiteralPath $rpcCli) "RPC CLI not found: $rpcCli"
Assert-True (Test-Path -LiteralPath (Join-Path $ProjectRoot 'matlab') -PathType Container) "matlab/ tree not found"

if (-not (Test-ServerAlive)) {
    if ($StartServer) {
        Start-MatlabServer
    } else {
        Log "ERROR: no live shared MATLAB RPC server for $WorkDir."
        Log "       Start one (unconfined MATLAB required) or rerun with -StartServer."
        Save-Log
        exit 3
    }
} else {
    $st = Get-ServerState
    Log "reusing live MATLAB RPC server pid=$($st.pid) matlab=$($st.matlab_version)"
}

$examples = @('enzyme_mm', 'goodwin', 'sir')
$fixtures = @('enzyme_kinetics', 'gene_oscillator', 'epidemic_sir')
$specDir = Join-Path $ProjectRoot 'spec\examples'
$dataDir = Join-Path $specDir 'data'
$fixtureRoot = Join-Path $ProjectRoot 'tests\fixtures\literature'
$script:transport = Resolve-Transport
Log "RPC transport: $($script:transport)"

# ===========================================================================
# 1. server + run management
# ===========================================================================
$ping = $null
Check 'server.ping' {
    $script:ping = Rpc 'server.ping' @{}
    Assert-True ($null -ne $script:ping.matlab_version) 'no matlab_version'
    Assert-True ($null -ne $script:ping.project_root) 'no project_root'
    "matlab=$($script:ping.matlab_version) pid=$($script:ping.pid)"
}
Check 'server.info (license/toolboxes)' {
    $info = Rpc 'server.info' @{}
    Assert-True ($null -ne $info.licensed) 'no licensed map'
    "matlab=$($info.matlab_version)"
}

$runDir = $null
Check 'run.init' {
    $script:runInfo = Rpc 'run.init' @{ name = "qa-tool-layer-$stamp" }
    Assert-True ("$($script:runInfo.run_dir)".Length -gt 0) 'no run_dir'
    $abs = Get-RelPath $WorkDir "$($script:runInfo.run_dir)"
    Assert-True (Test-Path -LiteralPath $abs) "run dir missing: $abs"
    foreach ($d in @('literature', 'models', 'data', 'fits', 'figures', 'report', 'logs')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $abs $d)) "run layout missing $d/"
    }
    $script:runDir = "$($script:runInfo.run_dir)"
    $script:runAbs = $abs
    "run_dir=$($script:runInfo.run_dir)"
}

# ===========================================================================
# 2. knowledge base
# ===========================================================================
Check 'kb.list' {
    $r = Rpc 'kb.list' @{ limit = 200 }
    $n = Assert-Array $r.items 'kb items'
    Assert-True ([int]$r.total -ge 10) "kb total too small ($($r.total))"
    $script:kbFirstId = "$($r.items[0].id)"
    Log "  kb total=$($r.total) (first id: $($script:kbFirstId))"
    "items=$n total=$($r.total)"
}
Check 'kb.search' {
    $r = Rpc 'kb.search' @{ query = 'negative feedback oscillator'; limit = 5 }
    $n = Assert-Array $r.hits 'kb hits'
    Assert-True ($null -ne $r.hits[0].score) 'hit has no score'
    Assert-True ((@($r.hits[0].matched_terms)).Count -gt 0) 'hit has no matched_terms'
    Assert-File $ProjectRoot "$($r.hits[0].path)" 'kb hit path' | Out-Null
    "hits=$n top=$($r.hits[0].id)"
}
Check 'kb.get' {
    $r = Rpc 'kb.get' @{ id = $script:kbFirstId }
    Assert-True ($null -ne $r.item) 'no item'
    Assert-True ("$($r.item.name)".Length -gt 0) 'item has no name'
    Assert-File $ProjectRoot "$($r.path)" 'kb item path' | Out-Null
    "id=$($r.item.id) type=$($r.item.type)"
}

# ===========================================================================
# 3. literature ingestion (fixtures, multiple formats)
# ===========================================================================
Check 'literature.ingest (3 fixtures x md/pdf)' {
    $ingested = 0; $factDetail = @()
    foreach ($fx in $fixtures) {
        $expFile = Join-Path (Join-Path $fixtureRoot $fx) 'expected_facts.json'
        $exp = Get-Content -LiteralPath $expFile -Raw | ConvertFrom-Json
        foreach ($ext in @('md', 'pdf')) {
            $src = Join-Path (Join-Path $fixtureRoot $fx) ("paper." + $ext)
            Assert-True (Test-Path -LiteralPath $src) "fixture missing: $src"
            $doc = Rpc 'literature.ingest' @{ path = $src; run_dir = $script:runDir }
            Assert-True ("$($doc.doc_id)".Length -gt 0) "no doc_id for $fx.$ext"
            Assert-True ([int]$doc.char_count -gt 2000) "char_count too small for $fx.$ext"
            Assert-True ((@($doc.sections)).Count -ge 5) "too few sections for $fx.$ext"
            Assert-True ((@($doc.numbers)).Count -ge 5) "too few numbers for $fx.$ext"
            Assert-File $WorkDir "$($doc.text_path)" "text_path $fx.$ext" | Out-Null
            Assert-File $WorkDir "$($doc.sections_path)" "sections_path $fx.$ext" | Out-Null
            Assert-File $WorkDir "$($doc.numbers_path)" "numbers_path $fx.$ext" | Out-Null
            if ($ext -eq 'md') {
                $factDetail += (Test-FactCoverage $exp $doc.numbers 0.8)
            }
            $ingested++
        }
    }
    "ingested=$ingested; " + ($factDetail -join '; ')
}

# ===========================================================================
# 4. spec.validate / model.build / model.analyze / model.simulate
# ===========================================================================
$specPaths = @{}
foreach ($ex in $examples) {
    $specPaths[$ex] = "spec/examples/$ex.json"
    Check "spec.validate ($ex)" {
        $r = Rpc 'spec.validate' @{ spec_path = $specPaths[$ex]; run_dir = $script:runDir }
        Assert-True ($r.valid -eq $true) "spec invalid: $(ConvertTo-Json $r.errors -Depth 6 -Compress)"
        Assert-True ($null -ne $r.normalized_spec) 'no normalized_spec'
        Assert-File $WorkDir "$($r.spec_path)" "normalized spec ($ex)" | Out-Null
        Assert-True ($r.units_check -ne $null) 'no units_check'
        "spec_path=$($r.spec_path) warnings=$((@($r.warnings)).Count)"
    }
    Check "model.build ($ex)" {
        $r = Rpc 'model.build' @{ spec_path = $specPaths[$ex]; run_dir = $script:runDir }
        Assert-True ((@($r.species)).Count -ge 2) 'too few species'
        Assert-True ($null -ne $r.network.stoichiometry) 'no stoichiometry matrix'
        Assert-True ((@($r.parameters)).Count -ge 2) 'too few parameters'
        "species=$((@($r.species)) -join ',') reactions=$($r.n_reactions)"
    }
    Check "model.analyze ($ex)" {
        $r = Rpc 'model.analyze' @{ spec_path = $specPaths[$ex]; run_dir = $script:runDir }
        Assert-File $WorkDir "$($r.analysis_path)" "analysis.json ($ex)" | Out-Null
        Assert-True ($null -ne $r.conservation_laws) 'no conservation_laws field'
        Assert-True ($null -ne $r.steady_states) 'no steady_states field'
        Assert-True ($r.dimensional_ok -eq $true) "dimensional check failed for $ex"
        "conservation_laws=$((@($r.conservation_laws)).Count) steady_states=$((@($r.steady_states)).Count)"
    }
    Check "model.simulate ($ex)" {
        $r = Rpc 'model.simulate' @{ spec_path = $specPaths[$ex]; run_dir = $script:runDir; options = @{ n = 201 } }
        Assert-File $WorkDir "$($r.timeseries_path)" "timeseries ($ex)" | Out-Null
        Assert-True ($null -ne $r.outputs -or $null -ne $r.final) 'no output summary'
        $figs = @($r.figures)
        "timeseries=$($r.timeseries_path) figures=$($figs.Count)"
    }
}

Check 'model.simulate_cases (sir scenarios)' {
    $cases = @(
        @{ name = 'low-transmission'; param_overrides = @{ beta = 0.2 } },
        @{ name = 'high-transmission'; param_overrides = @{ beta = 0.7 } }
    )
    $r = Rpc 'model.simulate_cases' @{ spec_path = $specPaths['sir']; run_dir = $script:runDir; cases = $cases }
    Assert-True ((@($r.cases)).Count -eq 2) "expected 2 case summaries"
    "cases=$((@($r.cases)).Count) comparison_figure=$($r.comparison_figure)"
}

# ===========================================================================
# 5. fitting / analysis tool surface (enzyme example)
# ===========================================================================
$dataCsv = Join-Path $dataDir 'enzyme_progress.csv'
$outMap = @{ P_obs = 'P_obs'; S_obs = 'S_obs' }
$fitResultPath = $null
Check 'fit.estimate (enzyme_mm synthetic data)' {
    $r = Rpc 'fit.estimate' @{
        spec_path    = $specPaths['enzyme_mm']
        run_dir      = $script:runDir
        data_csv     = $dataCsv
        output_map   = $outMap
        options      = @{ multistart = 4; max_iter = 300; seed = 42 }
    }
    Assert-File $WorkDir "$($r.fit_result_path)" 'fit.json' | Out-Null
    Assert-File $WorkDir "$($r.fitted_spec_path)" 'fitted_spec.json' | Out-Null
    Assert-True ($null -ne $r.metrics) 'no metrics'
    Assert-True ([double]$r.metrics.r2 -ge 0.90) "R2 too low: $($r.metrics.r2)"
    foreach ($m in @('r2', 'rmse', 'aicc', 'bic')) {
        Assert-True ($null -ne $r.metrics.$m) "metrics missing $m"
    }
    Assert-True ((@($r.params)).Count -ge 2) 'no parameter estimates'
    $script:fitResultPath = "$($r.fit_result_path)"
    "fit_id=$($r.fit_id) R2=$([math]::Round([double]$r.metrics.r2,4)) RMSE=$($r.metrics.rmse)"
}
Check 'fit.profile (kcat)' {
    $r = Rpc 'fit.profile' @{
        spec_path       = $specPaths['enzyme_mm']
        run_dir         = $script:runDir
        data_csv        = $dataCsv
        output_map      = $outMap
        param           = 'kcat'
        fit_result_path = $script:fitResultPath
        options         = @{ n = 7; max_iter = 120 }
    }
    Assert-True ("$($r.param)" -eq 'kcat') 'param not echoed'
    Assert-True ((@($r.values)).Count -ge 5) 'too few profile points'
    Assert-True ((@($r.nll)).Count -ge 5) 'no nll values'
    Assert-True ($null -ne $r.ci.low -and $null -ne $r.ci.high) 'no CI'
    Assert-True ([double]$r.ci.low -lt [double]$r.ci.high) 'CI not ordered'
    "CI=[$($r.ci.low), $($r.ci.high)]"
}
Check 'fit.sensitivity (local)' {
    $r = Rpc 'fit.sensitivity' @{
        spec_path = $specPaths['enzyme_mm']
        run_dir   = $script:runDir
        params    = @('kf', 'kr', 'kcat')
        method    = 'local'
    }
    Assert-True ($null -ne $r.indices) 'no indices'
    Assert-True ((@($r.indices.PSObject.Properties)).Count -ge 1) 'indices empty'
    "method=$($r.method) params=$((@($r.indices.PSObject.Properties.Name)) -join ',')"
}
Check 'fit.identifiability' {
    $r = Rpc 'fit.identifiability' @{
        spec_path   = $specPaths['enzyme_mm']
        run_dir     = $script:runDir
        data_csv    = $dataCsv
        output_map  = $outMap
        options     = @{}
    }
    Assert-True ($null -ne $r.structural) 'no structural analysis'
    Assert-True ($null -ne $r.practical) 'no practical analysis'
    Assert-True ($null -ne $r.rank) 'no rank'
    Assert-File $WorkDir "$($r.table_path)" 'identifiability table' | Out-Null
    "rank=$($r.rank)"
}

# ===========================================================================
# 6. validation tool surface
# ===========================================================================
Check 'validate.residuals' {
    $r = Rpc 'validate.residuals' @{ fit_result_path = $script:fitResultPath; run_dir = $script:runDir }
    Assert-True ($null -ne $r.diagnostics) 'no diagnostics'
    "diagnostics=$((@($r.diagnostics.PSObject.Properties.Name)) -join ',')"
}
Check 'validate.cross_validation (k=3)' {
    $r = Rpc 'validate.cross_validation' @{
        spec_path  = $specPaths['enzyme_mm']
        run_dir    = $script:runDir
        data_csv   = $dataCsv
        output_map = $outMap
        k          = 3
        options    = @{ multistart = 2; max_iter = 150 }
    }
    $n = Assert-Array $r.folds 'cv folds'
    Assert-True ($n -eq 3) "expected 3 folds, got $n"
    Assert-True ($null -ne $r.summary) 'no cv summary'
    "folds=$n"
}
Check 'validate.model_selection' {
    $candidates = @(
        @{ name = 'enzyme_mm'; spec_path = $specPaths['enzyme_mm']; data_csv = $dataCsv; output_map = $outMap },
        @{ name = 'enzyme_mm_b'; spec_path = $specPaths['enzyme_mm']; data_csv = $dataCsv; output_map = $outMap }
    )
    $r = Rpc 'validate.model_selection' @{ candidates = $candidates; run_dir = $script:runDir; options = @{} }
    $rows = @($r.table)
    Assert-True ($rows.Count -eq 2) "expected 2 candidate rows, got $($rows.Count)"
    Assert-True ("$($r.best)".Length -gt 0) 'no best model'
    Assert-File $WorkDir "$($r.table_path)" 'model selection table' | Out-Null
    "best=$($r.best)"
}

# ===========================================================================
# 7. report + codegen + simbiology
# ===========================================================================
Check 'report.build' {
    $r = Rpc 'report.build' @{
        run_dir         = $script:runDir
        title           = 'QA 工具层验收报告（酶动力学）'
        spec_path       = "spec/examples/enzyme_mm.json"
        fit_result_path = $script:fitResultPath
        analysis_path   = (Get-ChildItem -Path (Join-Path $script:runAbs 'models') -Recurse -Filter 'analysis.json' |
                           Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
        references      = @('Michaelis L, Menten ML (1913) Biochem Z 49:333-369')
    }
    Assert-File $WorkDir "$($r.report_html)" 'report.html' | Out-Null
    Assert-File $WorkDir "$($r.report_md)" 'report.md' | Out-Null
    Assert-File $WorkDir "$($r.model_card_path)" 'model_card.json' | Out-Null
    $md = Get-Content -LiteralPath (Get-RelPath $WorkDir "$($r.report_md)") -Raw
    Assert-True ($md.Length -gt 1500) 'report.md too short'
    Assert-True ($md -match '假设|assumption') 'report.md has no assumptions section'
    Assert-True ($md -match '证据|evidence|来源|出处') 'report.md has no evidence table'
    Assert-True ($md -match '参数|parameter') 'report.md has no parameter table'
    "report_md=$($r.report_md)"
}
Check 'codegen.model' {
    $r = Rpc 'codegen.model' @{ spec_path = $specPaths['enzyme_mm']; run_dir = $script:runDir }
    Assert-File $WorkDir "$($r.m_file)" 'generated .m' | Out-Null
    Assert-True ("$($r.function_name)".Length -gt 0) 'no function_name'
    $code = Get-Content -LiteralPath (Get-RelPath $WorkDir "$($r.m_file)") -Raw
    Assert-True ($code -match '^\s*function') 'generated file is not a function'
    "m_file=$($r.m_file) function=$($r.function_name)"
}
Check 'simbiology.export (optional)' {
    $r = Rpc 'simbiology.export' @{ spec_path = $specPaths['enzyme_mm']; run_dir = $script:runDir }
    Assert-True ($null -ne $r.ok) 'no ok field'
    "ok=$($r.ok) warnings=$((@($r.warnings)).Count)"
}

# ===========================================================================
# 8. run.list sees our run
# ===========================================================================
Check 'run.list' {
    $r = Rpc 'run.list' @{}
    $runs = @($r.runs)
    Assert-True ($runs.Count -ge 1) 'no runs listed'
    $ids = $runs | ForEach-Object { "$($_.run_dir)" }
    Assert-True (($ids -join ';') -match [regex]::Escape("$($script:runInfo.run_dir)")) 'created run not listed'
    "runs=$($runs.Count)"
}

# ===========================================================================
# summary
# ===========================================================================
$passed = @($script:results | Where-Object { $_.ok }).Count
$failed = @($script:results | Where-Object { -not $_.ok }).Count
Log ""
Log ("===== tool-layer E2E: {0} passed, {1} failed of {2} checks =====" -f $passed, $failed, $script:results.Count)
$summary = [pscustomobject]@{
    schema       = 'bma.e2e.tool_layer.v1'
    started_at   = $stamp
    finished_at  = (Get-Date -Format 'o')
    project_root = $ProjectRoot
    work_dir     = $WorkDir
    run_dir      = $script:runDir
    matlab       = $script:ping
    checks       = $script:results
    passed       = $passed
    failed       = $failed
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'summary.json') -Encoding UTF8

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Tool-layer E2E summary")
$md.Add("")
$md.Add("- Started: $stamp")
$md.Add("- Work dir: ``$WorkDir``")
$md.Add("- Run dir: ``$($script:runDir)``")
$md.Add("- Result: **$passed passed / $failed failed** of $($script:results.Count) checks")
$md.Add("")
$md.Add("| # | Check | Result | Detail |")
$md.Add("|---|---|---|---|")
$i = 0
foreach ($r in $script:results) {
    $i++
    $mark = if ($r.ok) { 'PASS' } else { '**FAIL**' }
    $rd = ("$($r.detail)").Replace('|', '\|').Replace("`n", ' ')
    $md.Add("| $i | $($r.name) | $mark | $rd |")
}
$md | Set-Content -LiteralPath (Join-Path $OutDir 'summary.md') -Encoding UTF8

Save-Log

if ($StopServer -and $script:startedByUs) {
    Log "stopping MATLAB RPC server (started by this script) ..."
    try { Rpc 'server.stop' @{} | Out-Null } catch { Log "WARNING: server.stop failed: $($_.Exception.Message)" }
}

if ($failed -gt 0) { exit 1 }
exit 0
