# run_headless_e2e.ps1
# =========================================================================
# Headless DSH end-to-end acceptance run (DESIGN §10.6).
#
# Builds an isolated workspace from a literature fixture, generates an overlay
# patch (restore DeepSeek credentials, inject the BioModel-MATLAB persona, mount
# the project MATLAB tool plugin), then runs a REAL DeepSeek model through
# `dsh --profile headless --patch <overlay> -` and finally asserts the produced
# modelling artifacts with assert_e2e.ps1.
#
# The agent must autonomously: ingest the paper, identify the model family,
# write a bma.modelSpec.v1, validate it, simulate, fit the fixture data,
# assess identifiability, and build a report with parameter evidence.
#
# Preconditions (must be run UNCONFINED, coordinated by the Lead):
#   * bridge/ package delivered and loadable by the profile;
#   * DeepSeek account credentials present in %USERPROFILE%\.dsh\.credentials.yaml
#     (this overlay re-enables the credential plugins that dsh-headless disables);
#   * write access to %USERPROFILE%\.dsh\profiles\headless (dsh rewrites cordis.yml);
#   * MATLAB R2024a spawnable by the bridge (unconfined MATLAB server).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/e2e/run_headless_e2e.ps1 `
#       -Fixture enzyme_kinetics -TimeoutMinutes 30
#
# Exit codes: 0 = E2E passed all assertions, 1 = assertions failed,
#             2 = agent run failed/timed out, 3 = preconditions not met
#             (including credentials unavailable - then use tool_layer_e2e.ps1).
#
# Idempotent: every invocation gets a new timestamped artifact directory; the
# previous artifacts are never modified.
# =========================================================================
[CmdletBinding()]
param(
    [ValidateSet('enzyme_kinetics', 'gene_oscillator', 'epidemic_sir')]
    [string]$Fixture = 'enzyme_kinetics',
    [string]$ProjectRoot = '',
    [string]$OutDir = '',
    [string]$Dsh = 'C:\Users\LEGION\AppData\Local\Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd',
    [int]$TimeoutMinutes = 30,
    [switch]$SkipConfigCheck,
    [switch]$SkipCredentialCheck,
    [switch]$DumpConfigOnly,
    [switch]$FailFast
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutDir) { $OutDir = Join-Path $ProjectRoot "tests\e2e\artifacts\headless-$stamp" }
$Workspace = Join-Path $OutDir 'workspace'
New-Item -ItemType Directory -Force -Path $OutDir, $Workspace, (Join-Path $Workspace 'literature'), (Join-Path $Workspace 'data') | Out-Null
$logFile = Join-Path $OutDir 'run_headless_e2e.log'
$script:logLines = New-Object System.Collections.Generic.List[string]

function Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    $script:logLines.Add($line)
}
function Save-Log { $script:logLines | Set-Content -LiteralPath $logFile -Encoding UTF8 }
function Fail([int]$code, [string]$msg) {
    Log "ERROR: $msg"
    Save-Log
    exit $code
}

Log "BioModel-MATLAB headless E2E"
Log "project root : $ProjectRoot"
Log "fixture      : $Fixture"
Log "artifacts    : $OutDir"
Log "workspace    : $Workspace"

# ---------------------------------------------------------------------------
# 0. preconditions
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Dsh)) { Fail 3 "dsh CLI not found: $Dsh" }
$bridgePkg = Join-Path $ProjectRoot 'bridge\package.json'
if (-not (Test-Path -LiteralPath $bridgePkg)) {
    Fail 3 ("bridge/plugin package not delivered yet ($bridgePkg missing). " +
            "Headless E2E cannot run; use tests/e2e/tool_layer_e2e.ps1 instead.")
}
$bridge = Get-Content -LiteralPath $bridgePkg -Raw | ConvertFrom-Json
$bridgeMain = "$($bridge.main)"
if (-not $bridgeMain) { $bridgeMain = 'lib\index.js' }
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot "bridge\$bridgeMain"))) {
    Fail 3 "bridge entry point $bridgeMain not found"
}
# Plugin spec: prefer a package installed into the headless profile, else an
# ABSOLUTE module path. The generated patch lives in the run's artifact
# directory, so relative paths anchored beside the patch file would resolve
# against the wrong place (regression found in the first headless run:
# ERR_MODULE_NOT_FOUND for tests/e2e/bridge). Absolute paths load reliably.
$profilePkg = Join-Path $env:USERPROFILE ".dsh\profiles\headless\node_modules\@local\dsh-bio-matlab"
$bridgeMainPath = Join-Path $ProjectRoot "bridge\$($bridgeMain -replace '/', '\')"
if (Test-Path -LiteralPath $profilePkg) {
    $pluginSpec = '@local/dsh-bio-matlab'
    Log "bridge plugin mount : installed profile package $pluginSpec"
} else {
    $pluginSpec = ($bridgeMainPath -replace '\\', '/')
    Log "bridge plugin mount : absolute path $pluginSpec"
}

# ---------------------------------------------------------------------------
# 1. materialise the workspace from the fixture (no ground-truth files copied)
# ---------------------------------------------------------------------------
$fixtureDir = Join-Path $ProjectRoot "tests\fixtures\literature\$Fixture"
if (-not (Test-Path -LiteralPath $fixtureDir)) { Fail 3 "fixture not found: $fixtureDir" }
foreach ($f in @('paper.md', 'paper.txt', 'paper.pdf', 'paper.docx')) {
    $src = Join-Path $fixtureDir $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $Workspace 'literature') -Force }
}
$dataSrc = Join-Path $fixtureDir 'data'
$dataFiles = @()
if (Test-Path -LiteralPath $dataSrc) {
    $dataFiles = @(Get-ChildItem -LiteralPath $dataSrc -Filter '*.csv' -File | Sort-Object Name)
    foreach ($df in $dataFiles) { Copy-Item -LiteralPath $df.FullName -Destination (Join-Path $Workspace 'data') -Force }
}
if (@($dataFiles).Count -eq 0) { Fail 3 "fixture has no data CSV under $dataSrc" }
Log ("workspace literature: " + ((Get-ChildItem -LiteralPath (Join-Path $Workspace 'literature')).Name -join ', '))
Log ("workspace data      : " + (($dataFiles | ForEach-Object { $_.Name }) -join ', '))

# hmm: literature files live in workspace/literature/; prompt uses one path
$taskPromptTpl = Get-Content -LiteralPath (Join-Path $ProjectRoot 'tests\e2e\headless_task_prompt.md') -Raw -Encoding UTF8
$expectedFit = if ($Fixture -eq 'enzyme_kinetics') {
    'data/progress_curve_S50.csv（P_uM→P_obs，S_uM→S_obs）'
} elseif ($Fixture -eq 'gene_oscillator') {
    'data/oscillation_timeseries.csv（mRNA_nM→m_obs，intermediate_nM→p_obs，repressor_nM→r_obs）'
} else {
    'data/community_cases.csv（active_infections→I_obs，cumulative_removed→R_obs）'
}
$taskPrompt = $taskPromptTpl.Replace('__WORKSPACE__', $Workspace).
    Replace('__FIXTURE_ID__', $Fixture).
    Replace('__LITERATURE_FILE__', 'literature/paper.md').
    Replace('__DATA_FILES__', (($dataFiles | ForEach-Object { 'data/' + $_.Name }) -join ', ')).
    Replace('__EXPECTED_FIT__', $expectedFit)
$promptFile = Join-Path $OutDir 'task_prompt.txt'
[System.IO.File]::WriteAllText($promptFile, $taskPrompt, (New-Object System.Text.UTF8Encoding($false)))
Log "task prompt written to $promptFile"

# ---------------------------------------------------------------------------
# 2. generate overlay patch
# ---------------------------------------------------------------------------
$patchTpl = Get-Content -LiteralPath (Join-Path $ProjectRoot 'tests\e2e\headless.patch.template.yml') -Raw -Encoding UTF8
$patchFile = Join-Path $OutDir 'headless.patch.yml'
[System.IO.File]::WriteAllText($patchFile, $patchTpl.Replace('__BIO_MATLAB_PLUGIN_SPEC__', $pluginSpec), (New-Object System.Text.UTF8Encoding($false)))
Log "overlay patch written to $patchFile"

# ---------------------------------------------------------------------------
# 3. verify the overlay composes (no LLM, no MATLAB): --dump-config
# ---------------------------------------------------------------------------
$dumpFile = Join-Path $OutDir 'composed_headless_config.yml'
$dumpErr = Join-Path $OutDir 'composed_headless_config.err.txt'
Log "composing headless profile with overlay (dsh --dump-config) ..."
& $Dsh --profile headless --patch $patchFile --dump-config 1> $dumpFile 2> $dumpErr
$dumpExit = $LASTEXITCODE
$dumpText = if (Test-Path -LiteralPath $dumpFile) { Get-Content -LiteralPath $dumpFile -Raw } else { '' }
$cfgOk = ($dumpExit -eq 0) -and ($dumpText -match 'bio-matlab-tools') -and
         ($dumpText -match 'BioModel-MATLAB') -and ($dumpText -match 'credentials')
if (-not $cfgOk) {
    $errText = if (Test-Path -LiteralPath $dumpErr) { (Get-Content -LiteralPath $dumpErr -Raw) } else { '' }
    if (-not $SkipConfigCheck) {
        Fail 3 ("overlay patch did not compose (exit $dumpExit). " +
                "This step needs an unconfined shell (it rewrites " +
                "%USERPROFILE%\.dsh\profiles\headless\cordis.yml). Output: $errText")
    } else {
        Log "WARNING: overlay composition check failed but -SkipConfigCheck was given: $errText"
    }
} else {
    Log "overlay composes: bio-matlab-tools + persona + credentials rows present"
}
if ($DumpConfigOnly) {
    Log "-DumpConfigOnly: stopping after overlay validation"
    Save-Log
    exit 0
}

# ---------------------------------------------------------------------------
# 4a. credential precondition for a real headless LLM run
# ---------------------------------------------------------------------------
# The stock headless profile disables the managed credential store, so the
# DeepSeek account login (device records in %USERPROFILE%\.dsh\.credentials.yaml)
# cannot be used. A headless run therefore needs an explicit API key
# (DEEPSEEK_API_KEY); the account-login path is exercised by the desktop Web GUI
# preset session instead (see tests/e2e/manual_acceptance_desktop.md).
if (-not $env:DEEPSEEK_API_KEY) {
    if (-not $SkipCredentialCheck) {
        Fail 3 ("DEEPSEEK_API_KEY is not set: a real headless LLM run would fail with " +
                "MISSING_CREDENTIAL (llm-deepseek: no API key for provider route 'deepseek-official'). " +
                "Set DEEPSEEK_API_KEY, or use the desktop Web GUI preset session path " +
                "(tests/e2e/manual_acceptance_desktop.md), or pass -SkipCredentialCheck to force the attempt.")
    }
    Log "WARNING: DEEPSEEK_API_KEY not set; forcing the run because -SkipCredentialCheck was given"
} else {
    Log "DEEPSEEK_API_KEY is set: real headless LLM run is possible"
}

# ---------------------------------------------------------------------------
# 4. run the real agent (wrapper avoids cmd.exe quoting pitfalls)
# ---------------------------------------------------------------------------
$wrapper = Join-Path $OutDir 'run_agent_wrapper.ps1'
$exitFile = Join-Path $OutDir 'agent.exitcode.txt'
$agentStdout = Join-Path $OutDir 'agent.stdout.log'
$agentStderr = Join-Path $OutDir 'agent.stderr.log'
$wrapperBody = @"
`$ErrorActionPreference = 'Continue'
Set-Location -LiteralPath '$Workspace'
`$task = Get-Content -LiteralPath '$promptFile' -Raw -Encoding UTF8
`$task | & '$Dsh' --profile headless --patch '$patchFile' --permission-mode danger-full-access --approval-policy never -
`$code = `$LASTEXITCODE
Set-Content -LiteralPath '$exitFile' -Value `$code -Encoding UTF8
exit `$code
"@
$wrapperBody | Set-Content -LiteralPath $wrapper -Encoding UTF8

Log "starting real DeepSeek agent (timeout ${TimeoutMinutes} min) ..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper) `
    -WorkingDirectory $Workspace -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput $agentStdout -RedirectStandardError $agentStderr
$exited = $proc.WaitForExit($TimeoutMinutes * 60 * 1000)
$sw.Stop()
$timedOut = $false
if (-not $exited) {
    $timedOut = $true
    Log "agent timed out after $TimeoutMinutes min; terminating process tree ..."
    & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
    Start-Sleep -Seconds 3
}
$agentExit = 'unknown'
if (Test-Path -LiteralPath $exitFile) { $agentExit = (Get-Content -LiteralPath $exitFile -Raw).Trim() }
Log "agent finished: exit=$agentExit elapsed=$([math]::Round($sw.Elapsed.TotalMinutes,1))min timedOut=$timedOut"

# record a compact run history for the acceptance report
$history = [pscustomobject]@{
    schema           = 'bma.e2e.headless_run.v1'
    fixture          = $Fixture
    started_at       = $stamp
    workspace        = $Workspace
    prompt_file      = $promptFile
    patch_file       = $patchFile
    agent_exit       = $agentExit
    timed_out        = $timedOut
    elapsed_seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    dsh              = $Dsh
}
$history | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutDir 'agent_run.json') -Encoding UTF8

# ---------------------------------------------------------------------------
# 5. assert produced artifacts
# ---------------------------------------------------------------------------
Log "running artifact/evidence assertions ..."
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProjectRoot 'tests\e2e\assert_e2e.ps1') `
    -Workspace $Workspace -Fixture $Fixture -ProjectRoot $ProjectRoot -OutDir $OutDir -AgentLog $agentStdout
$assertExit = $LASTEXITCODE
Log "assertions exit code: $assertExit"
Save-Log

if ($timedOut) { exit 2 }
if ($assertExit -ne 0) { exit 1 }
if ($agentExit -ne '0') { exit 2 }
exit 0
