# assert_e2e.ps1
# =========================================================================
# Artifact/evidence assertions for the headless agent E2E (DESIGN §10.6).
#
# Given the workspace in which a real DeepSeek agent ran (via
# run_headless_e2e.ps1), verify that the agent autonomously produced an
# acceptable modelling package:
#   * run directory + documented artifact layout;
#   * at least one valid-looking bma.modelSpec.v1 file;
#   * every parameter has a unit and evidence of type
#     measured/estimated/assumed/fitted (no fabricated parameters);
#   * the recognised model family matches tests/fixtures expected_facts.json
#     (species / rate-law kinds / mechanism keywords);
#   * expected parameter values are recovered (name- or value-matched with the
#     tolerance from expected_facts.json);
#   * a fit result exists with acceptable R2;
#   * report.html/report.md/model_card.json exist and the report contains the
#     parameter table, assumptions section, evidence table and figures.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/e2e/assert_e2e.ps1 `
#       -Workspace <artifacts\headless-...\workspace> -Fixture enzyme_kinetics `
#       -OutDir <artifacts\headless-...>
#
# Exit codes: 0 = all hard checks passed, 1 = failure.
# =========================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Workspace,
    [string]$Fixture = 'enzyme_kinetics',
    [string]$ProjectRoot = '',
    [string]$OutDir = '',
    [string]$AgentLog = '',
    [double]$MinR2 = 0.80,
    [switch]$FailFast
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$Workspace = (Resolve-Path -LiteralPath $Workspace).Path
if (-not $OutDir) { $OutDir = Split-Path -Parent $Workspace }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$script:results = New-Object System.Collections.Generic.List[object]
$script:failures = 0
$script:logLines = New-Object System.Collections.Generic.List[string]

function Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    $script:logLines.Add($line)
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
        if ($FailFast) { throw }
    }
}
function Assert-True([bool]$cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Read-JsonFile([string]$p) {
    Assert-True (Test-Path -LiteralPath $p) "file not found: $p"
    return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Get-Abs([string]$base, [string]$rel) {
    if ([System.IO.Path]::IsPathRooted($rel)) { return $rel }
    return (Join-Path $base ($rel -replace '/', '\'))
}
function Normalize-Unit([string]$u) {
    if (-not $u) { return '' }
    $s = $u.Trim().ToLowerInvariant()
    $s = $s.Replace([char]0x00B5, 'u').Replace([char]0x03BC, 'u')   # micro sign / greek mu
    $s = $s.Replace(" ", "").Replace("−", "-")
    $s = $s.Replace("^-1", "/").Replace("**", "^").Replace("*", "")
    $s = $s.Replace("per", "/")
    if ($s.EndsWith("/")) { $s = $s.Substring(0, $s.Length - 1) }
    return $s
}

# ---------------------------------------------------------------------------
# locate the newest run directory that contains a model spec
# ---------------------------------------------------------------------------
$runsRoot = Join-Path $Workspace '.bma\runs'
$runDirs = @()
if (Test-Path -LiteralPath $runsRoot) {
    $runDirs = @(Get-ChildItem -LiteralPath $runsRoot -Directory | Sort-Object LastWriteTime -Descending)
}
$specDir = $null
$spec = $null
Check 'run directory exists with artifact layout' {
    Assert-True ($runDirs.Count -ge 1) "no run directory under $runsRoot"
    foreach ($rd in $runDirs) {
        foreach ($d in @('models', 'data', 'fits', 'figures', 'report', 'logs')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $rd.FullName $d)) "run $($rd.Name) missing $d/"
        }
        break
    }
    "runs=" + ($runDirs.Count) + " newest=" + $runDirs[0].Name
}

Check 'model spec exists and is bma.modelSpec.v1' {
    $specFiles = @(Get-ChildItem -LiteralPath $runsRoot -Recurse -Filter 'spec.json' -File -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending)
    Assert-True ($specFiles.Count -ge 1) 'no spec.json produced under .bma/runs'
    $script:specPath = $specFiles[0].FullName
    $script:spec = Read-JsonFile $script:specPath
    Assert-True ("$($script:spec.schema_version)" -eq 'bma.modelSpec.v1') "schema_version is '$($script:spec.schema_version)'"
    Assert-True ((@($script:spec.variables)).Count -ge 1) 'spec has no variables'
    Assert-True ((@($script:spec.parameters)).Count -ge 1) 'spec has no parameters'
    Assert-True ((@($script:spec.reactions)).Count -ge 1) 'spec has no reactions'
    Assert-True ((@($script:spec.assumptions)).Count -ge 1) 'spec has no assumptions'
    "spec=$($script:specPath) vars=$((@($script:spec.variables)).Count) params=$((@($script:spec.parameters)).Count) reactions=$((@($script:spec.reactions)).Count)"
}

# ---------------------------------------------------------------------------
# parameter quality: units + evidence (no fabrication)
# ---------------------------------------------------------------------------
Check 'every parameter has a unit and evidence' {
    $params = @($script:spec.parameters)
    $validTypes = @('measured', 'estimated', 'assumed', 'fitted')
    $issues = @()
    foreach ($p in $params) {
        $id = "$($p.id)"
        if (-not "$($p.unit)" -or "$($p.unit)".Trim().Length -eq 0) { $issues += "$id:missing_unit" }
        $ev = @($p.evidence)
        if ($ev.Count -eq 0) { $issues += "$id:missing_evidence" }
        foreach ($e in $ev) {
            $t = "$($e.type)".ToLowerInvariant()
            if ($validTypes -notcontains $t) { $issues += "$id:bad_evidence_type=$t" }
        }
        if ($null -eq $p.value) { $issues += "$id:missing_value" }
    }
    Assert-True ($issues.Count -eq 0) ("parameter evidence issues: " + ($issues -join ', '))
    $nEv = 0; foreach ($p in $params) { $nEv += (@($p.evidence)).Count }
    "params=$($params.Count) evidence_entries=$nEv"
}

# ---------------------------------------------------------------------------
# model family vs expected_facts.json
# ---------------------------------------------------------------------------
$fixtureDir = Join-Path $ProjectRoot "tests\fixtures\literature\$Fixture"
$expPath = Join-Path $fixtureDir 'expected_facts.json'
$expectations = $null
Check 'expected facts available for fixture' {
    Assert-True (Test-Path -LiteralPath $expPath) "expectations not found: $expPath"
    $script:expectations = Read-JsonFile $expPath
    "fixture=$Fixture archetype=$($script:expectations.expected_model.archetype)"
}

Check 'recognised model family matches fixture' {
    $em = $script:expectations.expected_model
    $expSpecies = @($em.species) | ForEach-Object { "$_".ToLowerInvariant() }
    $gotSpecies = @(@($script:spec.variables) | ForEach-Object { "$($_.id)".ToLowerInvariant() })
    $speciesHit = 0
    foreach ($s in $expSpecies) { if ($gotSpecies -contains $s) { $speciesHit++ } }
    $need = [math]::Ceiling($expSpecies.Count / 2.0)

    $kindSet = @{}
    foreach ($r in @($script:spec.reactions)) { $k = "$($r.rate.kind)".ToLowerInvariant(); if ($k) { $kindSet[$k] = $true } }
    $gotKinds = @($kindSet.Keys)
    $expKinds = @($em.expected_reaction_kinds) | ForEach-Object { "$_".ToLowerInvariant() }
    $kindHits = 0
    foreach ($k in $expKinds) { if ($kindSet.ContainsKey($k)) { $kindHits++ } }

    $text = ("$($script:spec.name) $($script:spec.title) $($script:spec.description) " +
             ((@($script:spec.reactions) | ForEach-Object { "$($_.name) $($_.rate.kind)" }) -join ' ') + " " +
             ((@($script:spec.assumptions)) -join ' ')).ToLowerInvariant()
    $keywords = @($em.mechanism_keywords) + @($em.archetype_synonyms) + @($em.archetype)
    $kwHit = $false
    foreach ($kw in $keywords) {
        $k = "$kw".ToLowerInvariant()
        if ($k.Length -ge 3 -and $text.Contains($k)) { $kwHit = $true; break }
    }
    $detail = "species $speciesHit/$($expSpecies.Count) (need $need), kinds [$($gotKinds -join ',')] vs [$($expKinds -join ',')], keywords=$kwHit"
    Assert-True (($speciesHit -ge $need) -or ($kindHits -ge 1) -or $kwHit) "model family not recognisable: $detail"
    $detail
}

# ---------------------------------------------------------------------------
# expected parameter recovery
# ---------------------------------------------------------------------------
Check 'expected parameters recovered from literature' {
    $params = @($script:spec.parameters)
    $vars = @($script:spec.variables)
    $checked = 0; $matched = 0; $missing = @(); $unitWarn = @()
    foreach ($fact in @($script:expectations.facts)) {
        if (-not $fact.expected_in_spec) { continue }
        if ($null -eq $fact.value) { continue }
        $checked++
        $tv = [double]$fact.value
        $tol = 0.02 * [math]::Max([math]::Abs($tv), 1.0)
        if ($fact.tolerance) {
            if ($null -ne $fact.tolerance.relative) { $tol = [math]::Max($tol, [double]$fact.tolerance.relative * [math]::Abs($tv)) }
            if ($null -ne $fact.tolerance.absolute) { $tol = [math]::Max($tol, [double]$fact.tolerance.absolute) }
        }
        $names = @()
        if ($fact.id) { $names += "$($fact.id)" }
        if ($fact.symbol) { $names += "$($fact.symbol)" }
        foreach ($n in @($fact.names)) { if ($n) { $names += "$n" } }

        $hit = $null; $hitValue = $null; $hitUnit = $null
        # role "initial" may live in variables[].initial instead of parameters
        if ("$($fact.role)" -eq 'initial') {
            foreach ($v in $vars) {
                foreach ($n in $names) {
                    if ("$($v.id)" -ieq $n) {
                        $hit = $v; $hitValue = [double]$v.initial.value; $hitUnit = "$($v.unit)"; break
                    }
                }
                if ($null -ne $hit) { break }
            }
        }
        if ($null -eq $hit) {
            # 1) exact id / symbol match (case-insensitive)
            foreach ($p in $params) {
                foreach ($n in $names) {
                    if ("$($p.id)" -ieq $n) { $hit = $p; break }
                }
                if ($null -ne $hit) { break }
            }
        }
        if ($null -eq $hit) {
            # 2) numeric value match inside tolerance
            foreach ($p in $params) {
                $pv = $null
                if ($null -ne $p.value.value) { $pv = [double]$p.value.value }
                elseif ($null -ne $p.value -and $p.value -is [double]) { $pv = [double]$p.value }
                if ($null -ne $pv -and [math]::Abs($pv - $tv) -le $tol) { $hit = $p; $hitValue = $pv; break }
            }
        }
        if ($null -ne $hit) {
            if ($null -eq $hitValue) {
                if ($null -ne $hit.value -and $null -ne $hit.value.value) { $hitValue = [double]$hit.value.value }
                elseif ($null -ne $hit.initial -and $null -ne $hit.initial.value) { $hitValue = [double]$hit.initial.value }
            }
            $hitUnit = if ("$($hit.unit)" -ne '') { "$($hit.unit)" } else { $hitUnit }
            $ok = ($null -ne $hitValue) -and ([math]::Abs($hitValue - $tv) -le $tol)
            if ($ok) {
                $matched++
                if ($fact.unit -and $hitUnit -and (Normalize-Unit "$($fact.unit)") -ne (Normalize-Unit $hitUnit)) {
                    $unitWarn += "$($fact.id): '$hitUnit' vs '$($fact.unit)'"
                }
            } else {
                $missing += ("$($fact.id) (found $hitValue vs $tv)")
            }
        } else {
            $missing += "$($fact.id)"
        }
    }
    Assert-True ($checked -ge 3) "expected_facts has too few expected_in_spec facts ($checked)"
    $frac = $matched / [double]$checked
    $detail = "$matched/$checked expected parameters recovered"
    if ($unitWarn.Count -gt 0) { Log ("  WARN unit spelling: " + ($unitWarn -join '; ')) }
    if ($missing.Count -gt 0) { $detail += " (missing: " + ($missing -join '; ') + ")" }
    Assert-True ($frac -ge 0.60) "parameter recovery too low: $detail"
    $detail
}

# ---------------------------------------------------------------------------
# fit result
# ---------------------------------------------------------------------------
Check 'fit result exists with acceptable fit quality' {
    $fitFiles = @(Get-ChildItem -LiteralPath $runsRoot -Recurse -Filter 'fit.json' -File -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
    Assert-True ($fitFiles.Count -ge 1) 'no fit.json produced (no parameter estimation was completed)'
    $fit = Read-JsonFile $fitFiles[0].FullName
    Assert-True ($null -ne $fit.params) 'fit.json has no params'
    Assert-True ((@($fit.params)).Count -ge 1) 'fit.json lists no parameters'
    $fitDir = Split-Path -Parent $fitFiles[0].FullName
    Assert-True (Test-Path -LiteralPath (Join-Path $fitDir 'params.csv')) 'fit params.csv missing'
    $r2 = $null
    if ($null -ne $fit.metrics -and $null -ne $fit.metrics.r2) { $r2 = [double]$fit.metrics.r2 }
    if ($null -ne $r2) {
        Assert-True ($r2 -ge $MinR2) "fit R2 $r2 below threshold $MinR2"
        "fit=$($fitFiles[0].Name) R2=$([math]::Round($r2,4))"
    } else {
        "fit=$($fitFiles[0].Name) R2=not_reported"
    }
}

# ---------------------------------------------------------------------------
# report completeness
# ---------------------------------------------------------------------------
Check 'report exists with parameter table, assumptions and evidence' {
    $reports = @(Get-ChildItem -LiteralPath $runsRoot -Recurse -Filter 'report.md' -File -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending)
    Assert-True ($reports.Count -ge 1) 'no report.md produced'
    $reportDir = $reports[0].Directory
    $md = Get-Content -LiteralPath $reports[0].FullName -Raw -Encoding UTF8
    Assert-True (Test-Path -LiteralPath (Join-Path $reportDir 'report.html')) 'report.html missing'
    Assert-True (Test-Path -LiteralPath (Join-Path $reportDir 'model_card.json')) 'model_card.json missing'
    Assert-True ($md.Length -gt 2000) "report.md too short ($($md.Length) chars)"
    Assert-True ($md -match '假设|assumption|Assumptions') 'report has no assumptions section'
    Assert-True ($md -match '证据|evidence|Evidence|来源|出处') 'report has no evidence table'
    Assert-True ($md -match '参数|parameter|Parameter') 'report has no parameter table'
    Assert-True ($md -match '(测量|估计|拟合|measured|estimated|assumed|fitted)') 'report does not state parameter provenance'
    $ids = @(@($script:spec.parameters) | ForEach-Object { "$($_.id)" })
    $idHits = 0
    foreach ($id in $ids) { if ($md.ToLowerInvariant().Contains($id.ToLowerInvariant())) { $idHits++ } }
    Assert-True ($idHits -ge 2) "report mentions only $idHits parameter ids"
    # at least one referenced figure must exist
    $figCount = 0
    foreach ($sub in @('figures', 'report\figures')) {
        $fd = Join-Path $reportDir $sub
        if (Test-Path -LiteralPath $fd) { $figCount += (@(Get-ChildItem -LiteralPath $fd -Filter '*.png' -File)).Count }
    }
    # figures are usually under <run>/figures
    $runFigs = Get-ChildItem -LiteralPath $runsRoot -Recurse -Filter '*.png' -File -ErrorAction SilentlyContinue
    Assert-True (@($runFigs).Count -ge 1) 'no figures were produced'
    "report=$($reports[0].FullName) chars=$($md.Length) figure_files=$((@($runFigs)).Count)"
}

# ---------------------------------------------------------------------------
# agent log sanity (tool errors are not automatically fatal, but reported)
# ---------------------------------------------------------------------------
Check 'agent run log scanned' {
    if (-not $AgentLog) { return 'no agent log supplied' }
    if (-not (Test-Path -LiteralPath $AgentLog)) { return 'agent log missing' }
    $log = Get-Content -LiteralPath $AgentLog -Raw -Encoding UTF8
    $errCount = ([regex]::Matches($log, 'BMA_[A-Z_]+')).Count
    $out = "log_chars=$($log.Length) bma_error_mentions=$errCount"
    if ($errCount -gt 0) { Log "  WARN agent log contains $errCount BMA_* error mentions (see log)" }
    $out
}

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
$passed = @($script:results | Where-Object { $_.ok }).Count
$failed = @($script:results | Where-Object { -not $_.ok }).Count
Log ("===== headless E2E assertions: {0} passed, {1} failed of {2} =====" -f $passed, $failed, $script:results.Count)

$summary = [pscustomobject]@{
    schema    = 'bma.e2e.headless_assert.v1'
    fixture   = $Fixture
    workspace = $Workspace
    spec_path = $script:specPath
    finished  = (Get-Date -Format 'o')
    checks    = $script:results
    passed    = $passed
    failed    = $failed
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'e2e_assertions.json') -Encoding UTF8
$mdOut = New-Object System.Collections.Generic.List[string]
$mdOut.Add("# Headless E2E assertions ($Fixture)")
$mdOut.Add("")
$mdOut.Add("- Workspace: ``$Workspace``")
$mdOut.Add("- Spec: ``$($script:specPath)``")
$mdOut.Add("- Result: **$passed passed / $failed failed**")
$mdOut.Add("")
$mdOut.Add("| # | Check | Result | Detail |")
$mdOut.Add("|---|---|---|---|")
$i = 0
foreach ($r in $script:results) {
    $i++
    $mark = if ($r.ok) { 'PASS' } else { '**FAIL**' }
    $rd = ("$($r.detail)").Replace('|', '\|').Replace("`n", ' ')
    $mdOut.Add("| $i | $($r.name) | $mark | $rd |")
}
$mdOut | Set-Content -LiteralPath (Join-Path $OutDir 'e2e_assertions.md') -Encoding UTF8
$script:logLines | Set-Content -LiteralPath (Join-Path $OutDir 'e2e_assertions.log') -Encoding UTF8

if ($failed -gt 0) { exit 1 }
exit 0
