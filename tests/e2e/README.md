# End-to-end acceptance (tests/e2e)

Three paths are provided; all write timestamped artifacts under
`tests/e2e/artifacts/` (git-ignored), are idempotent, and log every step.

## Latest automated acceptance result (2026-11-14)

| Path | Result | Evidence |
|---|---|---|
| `tool_layer_e2e.ps1` | **31/31 PASS** (2026-11-14, control server) | `artifacts/tool-layer-20261114-003431/summary.{md,json}` + 36 RPC captures |
| `bridge/test/worker-isolation.test.mjs` | **14/14 PASS** | analyze 走 worker；worker 阻塞时 control 139 ms 响应；cancel 只重启 worker |
| `matlab/tests/test_upgrade_050.m` | **1/1 PASS** | analyze numeric fallback / report images / artifact / gate / section confidence / KB |
| `bridge/test/resilience.test.mjs` | **9/9 PASS** | timeout no-retry + restart + health + bma_cancel |
| `matlab/tests/test_integration_*.m` | **4/4 PASS** | `.qa/test-artifacts/it-{contract,lit,fittools,fullchain}-*` |
| headless real-LLM | blocked on `DEEPSEEK_API_KEY`; desktop preset session is the account-login path | `manual_acceptance_desktop.md` |

| Path | What it proves | Requirements |
|---|---|---|
| `tool_layer_e2e.ps1` | Every `bma_*` tool equivalent works end-to-end through the MATLAB JSON-RPC, with contract assertions (DESIGN §4, §5, §7). **Primary automated acceptance path.** | a live MATLAB RPC server for the chosen `-WorkDir` (start with `rpc-cli --start`, see below) |
| `run_headless_e2e.ps1` + `assert_e2e.ps1` | A **real DeepSeek model** autonomously turns a fixture paper into a validated spec, a fit, and an evidence-backed report (DESIGN §10.6). | unconfined shell, **`DEEPSEEK_API_KEY`**, delivered `bridge/` plugin, MATLAB R2024a |
| Desktop preset session (manual) | Same real-model acceptance through the Web GUI, where DeepSeek account login is valid. | Web GUI + installed `preset-bio-matlab`; see `manual_acceptance_desktop.md` |

> **Why the split:** the headless profile disables the managed credential store by design,
> so a DeepSeek account login cannot be used there — a headless LLM run needs an explicit
> `DEEPSEEK_API_KEY` (otherwise the agent fails with
> `MISSING_CREDENTIAL: llm-deepseek: no API key for provider route "deepseek-official"`).
> The real-model acceptance therefore primarily uses the desktop preset session; the
> headless runner remains ready for API-key environments. When neither is available,
> the tool-layer E2E is the documented degraded path (DESIGN §10.6).

## MATLAB RPC server topology

Each agent/session owns a private server (no shared keeper). From a shell in the project:

```powershell
# start (or reuse) a private server for this work dir
node bridge/lib/rpc-cli.mjs --work-dir "E:\matlab系统建模\.tmp\dev-qa" --start

# sanity check
node bridge/lib/rpc-cli.mjs --work-dir "E:\matlab系统建模\.tmp\dev-qa" --method server.ping --params "{}"

# stop when done
node bridge/lib/rpc-cli.mjs --work-dir "E:\matlab系统建模\.tmp\dev-qa" --stop
```

Notes:
- `rpc-cli --timeout` is in **seconds**; `--params-file <file.json>` avoids PS 5.1 quoting issues.
- The server is single-threaded: run long test batches serially and give them generous timeouts.
- If a call returns `BMA_SERVER_ABSENT`/`BMA_TIMEOUT`/`BMA_AUTH`, the server was restarted or is
  queued — start it again and retry once.
- Sandboxed sessions may not be able to enumerate the server PID, so `tool_layer_e2e.ps1`
  speaks the documented **file protocol directly** (`-Transport file`, the default):
  it reads `token` from `<work-dir>/.bma/server/state.json`, writes the request JSON
  (UTF-8 without BOM — MATLAB `jsondecode` rejects a leading BOM), and polls `outbox/`.
  `-Transport cli` additionally exercises `bridge/lib/rpc-cli.mjs` + `bridge-client.js`.

## Tool-layer E2E

```powershell
# 1) start your private MATLAB server (once per session)
node bridge/lib/rpc-cli.mjs --work-dir "E:\matlab系统建模\.tmp\dev-qa" --start

# 2) run the tool-layer acceptance (file protocol, no -StartServer needed)
powershell -NoProfile -ExecutionPolicy Bypass -File tests/e2e/tool_layer_e2e.ps1 `
    -WorkDir "E:\matlab系统建模\.tmp\dev-qa"
```

- Runs: `server.ping/info`, `run.init/list`, `kb.list/search/get`,
  `literature.ingest` (3 fixtures × md + pdf, cross-checked against
  `expected_facts.json`), `spec.validate/build/analyze/simulate` for all three
  example models, `model.simulate_cases`, `fit.estimate/profile/sensitivity/
  identifiability`, `validate.residuals/cross_validation/model_selection`,
  `report.build`, `codegen.model`, `simbiology.export`.
- Relative fixture/spec paths are resolved by the MATLAB dispatcher against the
  project root fallback, but absolute paths are recommended in scripts.
- Exit codes: `0` pass, `1` failed checks, `3` no MATLAB RPC server available.
- `-StartServer` is available for unconfined shells and spawns a detached
  `matlab -batch` server itself; `-StopServer` stops only a server this script started.

## Headless agent E2E

```powershell
# 1. validate the overlay patch only (no LLM, fast)
powershell -NoProfile -ExecutionPolicy Bypass -File tests/e2e/run_headless_e2e.ps1 `
    -Fixture enzyme_kinetics -DumpConfigOnly

# 2. full autonomous run + assertions (needs DEEPSEEK_API_KEY)
$env:DEEPSEEK_API_KEY = '<key>'
powershell -NoProfile -ExecutionPolicy Bypass -File tests/e2e/run_headless_e2e.ps1 `
    -Fixture enzyme_kinetics -TimeoutMinutes 30
```

What the runner does:

1. Copies one literature fixture (`paper.md/.txt/.pdf` + `data/*.csv`) into an
   isolated `workspace/`; **ground truth (`expected_facts.json`) is never copied**.
2. Renders `headless.patch.template.yml` (overlay patch):
   - re-enables `authorization`, `deepseek-account`, `credentials` (the stock
     `@deepseek-ai/dsh-headless` bundle disables them);
   - replaces `system-prompt.personaPrefix` with the BioModel-MATLAB persona;
   - inserts the project tool plugin (`bridge/`) as row `bio-matlab-tools`,
     using an **absolute module path** (`E:/matlab系统建模/bridge/lib/index.js`)
     or an installed profile package. (Relative anchoring failed in the first
     run because the generated patch lives in the run's artifact directory —
     `ERR_MODULE_NOT_FOUND`.)
3. Composes the profile with `dsh --profile headless --patch ... --dump-config`
   and checks the three row groups are present (needs unconfined shell: dsh
   rewrites `%USERPROFILE%\.dsh\profiles\headless\cordis.yml`).
4. Checks `DEEPSEEK_API_KEY` (fails fast with exit 3 otherwise; the desktop
   preset session is the account-login path), then runs
   `dsh --profile headless --patch <overlay> --permission-mode danger-full-access
   --approval-policy never -` with the task prompt on stdin, from the isolated
   workspace (so `.bma/runs/` lands there).
5. `assert_e2e.ps1` checks: run layout, `bma.modelSpec.v1` spec, every parameter
   with unit + `measured|estimated|assumed|fitted` evidence, model family vs
   `expected_facts.json`, parameter recovery within tolerance, fit result with
   R², and a report containing assumptions + evidence + parameter table + figures.

Exit codes: `0` pass, `1` assertions failed, `2` agent failed/timed out,
`3` preconditions not met (no bridge plugin, no `DEEPSEEK_API_KEY`, overlay not
composable). When real-LLM acceptance is not possible, the tool-layer E2E is the
documented degraded path and the limitation is recorded in `docs/ACCEPTANCE.md`.

### Overlay patch notes

- `headless.patch.yml` is the static reference version of the generated patch.
- `.patch` overlays are layered after the profile's own `cordis.patch.yml`, so
  no file under `%USERPROFILE%\.dsh\profiles\headless` needs to be edited by
  hand for the E2E.
- Credentials: the patch re-enables the plugins that read the credential store,
  but headless LLM routing still requires an API key; account device records are
  not accepted there. No secret is printed or copied into the artifacts.

## Artifacts

```
tests/e2e/artifacts/
├─ tool-layer-<ts>/        summary.md/json, rpc/*.json, params/*, tool_layer_e2e.log
└─ headless-<ts>/          task_prompt.txt, headless.patch.yml, composed_headless_config.yml,
                           agent.stdout.log, agent.stderr.log, agent_run.json,
                           e2e_assertions.md/json, run_headless_e2e.log,
                           workspace/ (the agent's isolated work_dir with .bma/runs/...)
```
