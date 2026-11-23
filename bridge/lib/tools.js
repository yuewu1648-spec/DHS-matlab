/**
 * Model-facing tool definitions for the BioModel-MATLAB agent.
 *
 * Each entry maps one `bma_*` tool to one MATLAB RPC method. Complex
 * arguments are JSON strings (`*_json`) so the model-facing schema stays
 * simple and stable, and every tool declares its own cooperative timeout.
 *
 * The MATLAB side owns all science: these definitions only resolve paths,
 * call the bridge and render a compact text summary for the model.
 */

const PROJECT_LABEL = 'MATLAB bma'

// The DSH schema DSL accepts `required` only when true; omit it otherwise.
function stringField(description, required) {
  const field = { type: 'string', description }
  if (required === true) field.required = true
  return field
}

/** JSON-string parameter helper. */
function jsonParam(description, required = false) {
  return stringField(description, required)
}

function numParam(description) {
  return { type: 'number', description }
}

function strParam(description, required = false) {
  return stringField(description, required)
}

function boolParam(description) {
  return { type: 'boolean', description }
}

function parseJsonArg(value, name, fallback) {
  if (value === undefined || value === null || value === '') return fallback
  try {
    return JSON.parse(value)
  } catch (err) {
    throw new Error(`invalid ${name}: not valid JSON (${err.message})`)
  }
}

/**
 * Accept either a JSON literal or a plain string/path. Used by report
 * extra_sections_json (a JSON array OR a path to a JSON/Markdown file) and by
 * gate evidence. JSON-looking values are parsed; everything else is passed
 * through as a string instead of failing in the tool layer.
 */
function parseJsonOrStringArg(value, name, fallback) {
  if (value === undefined || value === null || value === '') return fallback
  const text = String(value).trim()
  if (text.startsWith('[') || text.startsWith('{') || text.startsWith('"')) {
    try {
      return JSON.parse(text)
    } catch (err) {
      throw new Error(`invalid ${name}: not valid JSON (${err.message})`)
    }
  }
  return text
}

function clip(text, max = 6000) {
  const s = typeof text === 'string' ? text : JSON.stringify(text, null, 2)
  return s.length > max ? `${s.slice(0, max)}\n... (truncated, ${s.length} chars)` : s
}

function listLines(items, render, limit = 12) {
  const rows = []
  const n = Math.min(items?.length ?? 0, limit)
  for (let i = 0; i < n; i += 1) rows.push(render(items[i], i))
  if ((items?.length ?? 0) > limit) rows.push(`... (${items.length - limit} more)`)
  return rows
}

function fmtNumber(v, digits = 4) {
  if (v === null || v === undefined) return 'n/a'
  if (typeof v !== 'number' || !Number.isFinite(v)) return String(v)
  if (v !== 0 && (Math.abs(v) < 1e-3 || Math.abs(v) >= 1e5)) return v.toExponential(3)
  return Number(v.toFixed(digits)).toString()
}

function summariseMetrics(m = {}) {
  const parts = []
  for (const key of ['r2', 'rmse', 'nrmse', 'aicc', 'bic', 'loglik', 'n']) {
    if (m[key] !== undefined && m[key] !== null) {
      parts.push(`${key}=${key === 'n' ? m[key] : fmtNumber(m[key])}`)
    }
  }
  return parts.join(' ')
}

function summariseParams(params = [], limit = 20) {
  return listLines(
    params,
    (p) => {
      const fixed = p.fixed ? ' (fixed)' : ''
      const ci =
        p.ci_low !== undefined && p.ci_high !== undefined
          ? ` CI=[${fmtNumber(p.ci_low)}, ${fmtNumber(p.ci_high)}]`
          : ''
      return `- ${p.id} = ${fmtNumber(p.value)}${ci}${fixed}`
    },
    limit
  )
}

function summariseHealth(h = {}, prefix = '') {
  const lines = []
  const tag = prefix ? `${prefix} ` : ''
  if (h.busy) {
    lines.push(`- ${tag}server: BUSY ${h.current_call || '?'} for ${fmtNumber((h.busy_ms || 0) / 1000, 1)} s; queue=${h.queue_depth ?? 0}`)
  } else if (h.server_alive) {
    lines.push(`- ${tag}server: idle; queue=${h.queue_depth ?? 0}`)
  } else {
    lines.push(`- ${tag}server: not running`)
  }
  if (h.workspace_writable === false) {
    lines.push(`- ${tag}workspace writable: FALSE — .bma cannot be written by the bridge; artifacts will fail. Check the DSH sandbox ACL and run the workspace preflight.`)
  }
  if (h.last_timeout) {
    lines.push(`- ${tag}last timeout: ${h.last_timeout.method || '?'} at ${h.last_timeout.at || '?'} (${h.last_timeout.timeout_ms ?? '?'} ms)`)
  }
  if (h.last_error) {
    lines.push(`- ${tag}last error: ${h.last_error.code || '?'}: ${clip(h.last_error.message || '', 300)}`)
  }
  if (h.restarts) lines.push(`- ${tag}server restarts: ${h.restarts}`)
  return lines
}

/** Tool specification list. `method` is the MATLAB RPC method name. */
export const TOOL_SPECS = [
  {
    name: 'matlab_status',
    description:
      'Start or health-check the MATLAB R2024a backend for this session and report its version, licensed toolboxes, project paths, control-server health and heavy-worker health. Call this first in a modeling session. The first call may take 20-120 s because the control server and the isolated heavy worker boot in parallel; later calls are instant. Light calls (kb/run/status/validate) use the control server; analyze/simulate/fit/identifiability/report run in the worker, so a stuck builtin cannot freeze status or cancel. If a server died, the bridge detects it quickly, discards stale RPC state and restarts only that server. After the last bma_* call the bridge stops both MATLAB servers when idle for BMA_IDLE_SHUTDOWN_SECONDS (default 300; set 0 to disable), then lazily restarts them on the next call; this is normal resource reclamation, not a failure.\n\nReturns: MATLAB version, control/worker pid and state, project root, work directory, licensed toolboxes, and health fields (busy/queue/last_timeout/workspace_writable).\n\nNotes: work_dir defaults to the session working directory. Keeping all artifacts of a session under the same work_dir reuses the same control/worker pair.',
    timeoutMs: 240_000,
    method: 'server.info',
    parameters: {
      work_dir: strParam('Absolute directory for this modeling session. Omit to use the session working directory.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: () => ({}),
    summarize: (r, ctx = {}) => {
      const lic = r.licensed || {}
      const on = Object.entries(lic).filter(([, v]) => v).map(([k]) => k)
      const health = r.status || {}
      const worker = r.worker || {}
      const workerHealth = worker.status || {}
      const ready = r.server_alive !== false && (r.ok !== false)
      return [
        ready ? `MATLAB backend ready.` : `MATLAB backend is NOT ready.`,
        ctx.agentInfo && ctx.agentInfo.agentVersion ? `- agent version: ${ctx.agentInfo.agentVersion} (bundle ${ctx.agentInfo.bundleVersion}, spec schema ${ctx.agentInfo.specSchema})` : '',
        `- project root: ${r.project_root || (ctx.agentInfo && ctx.agentInfo.projectRoot) || ''}`,
        r.matlab_version ? `- version: ${r.matlab_version}` : '',
        r.pid ? `- control pid: ${r.pid}` : '',
        r.work_dir ? `- work dir: ${r.work_dir}` : '',
        on.length ? `- licensed: ${on.join(', ')}` : '',
        ...summariseHealth(health),
        worker.server_alive
          ? `- worker: ${worker.busy ? 'BUSY' : 'idle'}${worker.pid ? ` pid=${worker.pid}` : ''}${workerHealth.queue_depth !== undefined ? ` queue=${workerHealth.queue_depth}` : ''}`
          : (worker.start_error
              ? `- worker: NOT READY (${worker.start_error.code}: ${clip(worker.start_error.message || '', 300)})`
              : '- worker: not started'),
        ...summariseHealth(workerHealth, 'worker'),
        r.health_error ? `- health probe error: ${r.health_error.code}: ${r.health_error.message}` : '',
        r.start_error ? `- start error: ${r.start_error.code}: ${r.start_error.message}` : '',
        ready
          ? 'Artifacts live under <work_dir>/.bma/runs/<run_id>/; heavy calls run in the worker.'
          : 'Next: run bma_cancel (hard cancel/restart) or retry matlab_status; do not start another MATLAB server.',
      ].filter(Boolean).join('\n')
    },
  },

  {
    name: 'bma_cancel',
    description:
      'Cancel the current long-running MATLAB call and recover the heavy worker (and, if needed, the control server). Writes a cooperative cancel flag (checked by Sobol/fit loops), waits grace_seconds, then by default kills the busy MATLAB process tree. The replacement process starts lazily on the next heavy call, so bma_cancel itself is bounded and cannot hang on a slow MATLAB boot. Use after BMA_TIMEOUT or when matlab_status reports worker BUSY and a call is clearly stuck. Returns per-server cancelled/killed/method plus health snapshots.\n\nUse hard=false only when you want cooperative cancellation and to keep the current process; otherwise hard=true is the reliable recovery path.',
    timeoutMs: 180_000,
    method: 'server.cancel',
    parameters: {
      work_dir: strParam('Optional work directory override.'),
      hard: boolParam('Kill and restart the busy server if the call is still running after grace_seconds (default true).'),
      grace_seconds: numParam('Seconds to wait for cooperative cancellation before hard restart (default 3).'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => ({ hard: a.hard !== false, grace_seconds: a.grace_seconds ?? 3 }),
    summarize: (r) => {
      const one = (label, x = {}) => {
        const head = x.cancelled
          ? `${label}: cancel requested${x.killed || x.restarted ? (x.killed ? '; process killed' : '; restarted') : x.running ? '; still running (soft cancel)' : x.reason ? ` (${x.reason})` : ''}.`
          : `${label}: no running call${x.reason ? ` (${x.reason})` : ''}.`
        return [
          head,
          x.method ? `- ${label} target: ${x.method} (${x.rpc_id || '?'})` : '',
          x.restarts_on_next_call ? `- ${label}: replacement starts on the next call` : '',
          x.restart_error ? `- ${label} restart error: ${x.restart_error}` : '',
          ...summariseHealth(x.health || {}, label),
        ].filter(Boolean)
      }
      return [
        r.cancelled ? 'Cancel requested.' : 'No running call to cancel.',
        ...one('worker', r.worker || {}),
        ...one('control', r.control || {}),
      ].filter(Boolean).join('\n')
    },
  },

  {
    name: 'bma_artifact_import',
    description:
      'Copy files or a directory produced outside the run directory (for example by a MATLAB -batch subprocess that cannot write .bma under a sandbox ACL) into <run_dir>/artifacts/, with SHA-256 and artifacts.json provenance. bma_report_build scans artifacts/ and embeds images, so the final report stays self-contained. Use this instead of leaving report figures at absolute paths outside run_dir.\n\nReturns: imported count, artifact paths, artifacts.json path, and warnings. Source files are read-only inputs and may live outside the session workspace.',
    timeoutMs: 300_000,
    method: 'run.import_artifact',
    parameters: {
      source_path: strParam('File or directory to import (absolute, or relative to work_dir).', true),
      run_dir: strParam('Run directory that receives artifacts/. Omit to create/reuse the current run.'),
      name: strParam('Optional destination name (deduplicated automatically).'),
      kind: strParam('Optional free-form label (default inferred from extension).'),
      recursive: boolParam('Import directory contents recursively (default true).'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => {
      const p = { source_path: a.source_path }
      if (a.run_dir) p.run_dir = a.run_dir
      if (a.name) p.name = a.name
      if (a.kind) p.kind = a.kind
      if (a.recursive !== undefined) p.recursive = a.recursive
      return p
    },
    summarize: (r) => [
      `Artifact import: ${r.imported || 0} file(s).`,
      r.artifact_dir ? `- artifact dir: ${r.artifact_dir}` : '',
      r.artifacts_path ? `- manifest: ${r.artifacts_path}` : '',
      ...listLines(r.artifacts || [], (a) => `  - ${a.rel_path} (${a.bytes ?? '?'} bytes, ${a.kind || '?'})`, 20),
      (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
      'Report build will embed images from artifacts/ automatically.',
    ].filter(Boolean).join('\n'),
  },

  {
    name: 'bma_gate_waive',
    description:
      'Record an explicit, auditable quality-gate waiver in <run_dir>/gates.json (for example G6 when symbolic analysis is computationally infeasible). A waiver requires gate and reason; substitute names the numeric fallback actually used. bma_report_build renders a “quality gates and waivers” section and the model card records it, so a skipped gate is never silent. Do not use this to hide a gate you simply did not run: first try bma_model_analyze numeric fallback, then waive with evidence.',
    timeoutMs: 120_000,
    method: 'run.waive_gate',
    parameters: {
      gate: strParam('Gate id, e.g. "G6" or "G8".', true),
      reason: strParam('Why the gate is infeasible or only partially completed; include the evidence.', true),
      substitute: strParam('The fallback actually used, e.g. "numeric conservation nullspace + numerical Jacobian".'),
      evidence: strParam('Optional JSON value (object/array/string) with paths/metrics supporting the waiver.'),
      run_dir: strParam('Run directory. Omit to create/reuse the current run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => {
      const p = { gate: a.gate, reason: a.reason }
      if (a.substitute) p.substitute = a.substitute
      if (a.evidence) p.evidence = parseJsonOrStringArg(a.evidence, 'evidence', a.evidence)
      if (a.run_dir) p.run_dir = a.run_dir
      return p
    },
    summarize: (r) => [
      `Quality-gate waiver recorded: ${r.gate || '?'}`,
      r.reason ? `- reason: ${clip(r.reason, 500)}` : '',
      r.substitute ? `- substitute: ${r.substitute}` : '',
      r.duplicate ? '- note: this gate already had a waiver; both are kept for audit.' : '',
      r.count ? `- waivers in run: ${r.count}` : '',
      r.gates_path ? `- gates.json: ${r.gates_path}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
      'The report and model card will show this waiver explicitly.',
    ].filter(Boolean).join('\n'),
  },

  {
    name: 'bma_kb_search',
    description:
      'Search the built-in biological-systems modeling knowledge base (13 mechanistic archetypes + 14 first-principles and numerical checklists) by free text and optional tags. Use it to bridge literature evidence to a candidate model family: enzyme kinetics, gene expression, Hill regulation/toggle, negative-feedback oscillator, receptor-ligand, MAPK cascade, metabolic pathway, population dynamics, SIR/SEIR, pharmacokinetics, Hodgkin-Huxley, reaction-diffusion/Turing, chemotaxis, plus principles (mass action, conservation laws, dimensional analysis, QSSA, Hill/synergy, Fick, Nernst, thermodynamics, stochasticity, network motifs, stability/oscillation, R0/next-generation matrix) and MATLAB PDE/numerical convergence pitfalls.\n\nReturns: ranked hits with id/type/name/summary/score/matched terms, then call bma_kb_get for equations, assumptions, typical parameter ranges, spec_template and references.',
    timeoutMs: 120_000,
    method: 'kb.search',
    parameters: {
      query: strParam('Free-text query, Chinese or English (e.g. "负反馈 振荡 Hill negative feedback oscillator" or "Michaelis-Menten inhibition").', true),
      tags: jsonParam('Optional JSON array of tags to AND-filter, e.g. ["enzyme","oscillation"].'),
      limit: numParam('Maximum hits, default 8.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => ({
      query: a.query,
      tags: parseJsonArg(a.tags, 'tags', []),
      limit: a.limit ?? 8,
    }),
    summarize: (r) => [
      `Knowledge base hits: ${r.total ?? (r.hits || []).length}`,
      ...listLines(r.hits || [], (h) => `- [${h.type}] ${h.id} — ${h.name} (score ${fmtNumber(h.score, 2)})${h.path ? ` @ ${h.path}` : ''}\n    ${clip(h.summary || '', 220)}`),
    ].join('\n'),
  },

  {
    name: 'bma_kb_get',
    description:
      'Fetch one complete knowledge-base entry (archetype or principle) by id: equations (LaTeX + plain), assumptions, evidence cues from papers, typical parameter ranges with units, fitting and identifiability notes, a directly reusable bma.modelSpec.v1 spec_template, and references. Use after bma_kb_search to ground the model structure and assumptions.',
    timeoutMs: 120_000,
    method: 'kb.get',
    parameters: {
      id: strParam('Knowledge-base entry id, e.g. "enzyme_kinetics" or "principle_mass_action".', true),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => ({ id: a.id }),
    summarize: (r) => {
      const item = r.item || r
      const eq = (item.equations || []).map((e) => `  * ${e.name || ''}: ${e.plain || e.latex || ''}`).join('\n')
      const params = (item.parameters || []).map((p) => `  * ${p.id}: ${p.name || ''} [${p.unit || '?'}] typical ${JSON.stringify(p.typical_range || [])}`).join('\n')
      const vars = (item.variables || []).map((v) => `  * ${v.id}: ${v.name || ''} [${v.unit || '?'}]`).join('\n')
      return clip(
        [
          `[${item.type || 'entry'}] ${item.id} — ${item.name} (${item.name_en || ''})`,
          `domain: ${item.domain || ''} | scale: ${item.scale || ''} | model_class: ${item.model_class || ''}`,
          `summary: ${item.summary || ''}`,
          eq ? `equations:\n${eq}` : '',
          vars ? `variables:\n${vars}` : '',
          params ? `parameters:\n${params}` : '',
          `assumptions: ${(item.assumptions || []).join('; ')}`,
          item.fitting_notes ? `fitting_notes: ${item.fitting_notes}` : '',
          item.identifiability_notes ? `identifiability_notes: ${item.identifiability_notes}` : '',
          item.spec_template ? `spec_template (reusable JSON):\n${clip(JSON.stringify(item.spec_template), 3000)}` : '',
          item.references ? `references: ${(item.references || []).map((x) => x.citation || x).join(' | ')}` : '',
        ]
          .filter(Boolean)
          .join('\n'),
        9000
      )
    },
  },

  {
    name: 'bma_literature_ingest',
    description:
      'Parse a literature file (PDF, DOCX, TXT, Markdown, HTML) with MATLAB into a structured document: title, ordered sections with stable section ids AND sentence ids (section#sN, with character offsets), extracted numeric facts (value + unit + symbol + sentence_id + verbatim context), markdown/space-aligned tables, and PDF figures. PDF figure extraction uses **PyMuPDF** when available: it extracts embedded bitmaps and renders figure-sized vector drawing clusters to PNG; if PyMuPDF is unavailable it falls back to the pure-MATLAB bitmap extractor. Use this as step 1 of every modeling task, then quote evidence with section/sentence ids.\n\nReturns: doc_id, title, format, char count, section outline, sentence count/path, numbers count/path, tables path, figures count/path, figure_class (bitmap/vector/vector_or_mask/mixed), rasterized, and the top facts. Artifacts are written under <run_dir>/literature/<doc_id>/.\n\nNotes: PDF text extraction uses MATLAB Text Analytics; vector figures become `vector_render` PNGs via PyMuPDF; JPX/CCITT or unavailable PyMuPDF are reported in warnings. Numbers are candidates — verify each in context.',
    timeoutMs: 300_000,
    method: 'literature.ingest',
    parameters: {
      path: strParam('Path to the literature file (absolute, or relative to work_dir).', true),
      run_dir: strParam('Run directory (relative to work_dir or absolute). Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => {
      const p = { path: a.path }
      if (a.run_dir) p.run_dir = a.run_dir
      return p
    },
    summarize: (r) => [
      `Ingested ${r.format || '?'} document: ${r.title || r.doc_id}`,
      `- run_dir: ${r.run_dir}`,
      `- doc id: ${r.doc_id || 'n/a'} | chars: ${r.char_count ?? '?'} | sections: ${(r.sections || []).length} | sentences: ${r.sentence_count ?? (r.sentences || []).length} | numeric facts: ${(r.numbers || []).length} | tables: ${(r.tables || []).length} | figures: ${r.figure_count ?? (r.figures || []).length}`,
      `- full text: ${r.text_path}`,
      `- sections: ${r.sections_path}`,
      `- numbers: ${r.numbers_path}`,
      r.sentences_path ? `- sentences (section#sN citations): ${r.sentences_path}` : '',
      r.figures_path ? `- figures: ${r.figures_path}` : '',
      r.figure_class ? `- figure class: ${r.figure_class}${r.figures_rasterized ? ' (rasterized=true)' : (r.vector_only ? ' (vector/mask; rasterized=false, reason=' + (r.figure_reason || 'no_renderer') + ')' : '')}` : '',
      r.truncated !== undefined ? `- text: ${r.text_chars ?? r.char_count ?? '?'}/${r.text_chars_total ?? r.text_chars ?? r.char_count ?? '?'} chars; truncated=${r.truncated}${r.truncation_reason ? ' (' + r.truncation_reason + ')' : ''}` : '',
      `- section outline:`,
      r.section_confidence
        ? `- section confidence: ${r.section_confidence}${r.low_confidence_sections !== undefined ? ` (low ${r.low_confidence_sections}/${(r.sections || []).length}, ${Math.round((r.low_confidence_ratio || 0) * 100)}%)` : ''}`
        : '',
      ...listLines(r.sections || [], (s) => `  - ${s.id}${s.heading ? ` | ${s.heading}` : ''}${s.section_confidence === 'low' ? ' [low-confidence heading]' : ''} (${(s.text || '').length} chars)`, 20),
      `- extracted numeric facts (verify each against its context quote):`,
      ...listLines(r.numbers || [], (n) => `  - ${n.symbol || '?'} = ${fmtNumber(n.value)} [${n.unit || '?'}] in ${n.section_id || '?'}${n.sentence_id ? ' / ' + n.sentence_id : ''} :: ${clip((n.context || '').replace(/\s+/g, ' '), 160)}`, 20),
      (r.figures || []).length ? '- extracted figures (file | page | caption):' : '',
      ...listLines(r.figures || [], (f) => `  - ${f.rel_path || f.file} | page ${f.page ?? '?'} | ${clip(f.caption || '无图注', 120)}`, 10),
      (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
    ]
      .filter(Boolean)
      .join('\n'),
  },

  {
    name: 'bma_blind_start',
    description:
      'Seal a primary paper for BLIND-LIT modeling: extract ONLY its abstract, inventory ALL references (a folder, a JSON list and/or the paper bibliography), and make bma_literature_ingest refuse the primary full text until bma_blind_reveal. Use this when the user asks to model the question/goal of a paper using only its abstract plus all references.\n\nInputs: primary_path (required); abstract_path (authoritative UTF-8 text file with only the abstract; use when extraction is unreliable); references_dir (recursive PDF/DOCX/TXT/MD/HTML); references_json (JSON array of citations or {citation,path,url,doi} objects, or a path to such a JSON file); from_primary=true to parse the citation strings of the paper bibliography (only the citation strings are surfaced; the body stays sealed).\nOptions: title, min_rounds (default 3, minimum 2), budget_seconds (0 = none), max_references (default 300), force (overwrite an existing sealed protocol).\n\nReturns: the abstract text (the only primary content exposed), reference inventory + coverage, protocol/abstract paths, warnings and next steps. The primary body, figures and tables are never persisted or returned by this tool.\n\nNote: the seal blocks bma_literature_ingest by path AND SHA-256; do not read the primary file with read/pwsh during modeling (honesty rule of the protocol).',
    timeoutMs: 300_000,
    method: 'blind.start',
    parameters: {
      primary_path: strParam('Path to the primary paper (absolute, or relative to work_dir).', true),
      abstract_path: strParam('Optional UTF-8 text file containing ONLY the primary abstract (authoritative).'),
      references_dir: strParam('Optional folder of reference files (scanned recursively for PDF/DOCX/TXT/MD/HTML).'),
      references_json: jsonParam('Optional JSON array of citations or {citation,path,url,doi} objects, or a path to a JSON file.'),
      from_primary: boolParam('Parse the citation strings from the primary paper bibliography (citation metadata only; body stays sealed).'),
      title: strParam('Optional title override for the primary paper.'),
      min_rounds: numParam('Minimum self-check rounds before stop, default 3 (minimum 2).'),
      budget_seconds: numParam('Total modeling budget in seconds for over_budget accounting (0 = not declared).'),
      max_references: numParam('Hard cap on reference count, default 300 (never truncates silently).'),
      force: boolParam('Overwrite an existing blind protocol for this run (backs up the old protocol.json).'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => {
      const p = { primary_path: a.primary_path }
      if (a.abstract_path) p.abstract_path = a.abstract_path
      if (a.references_dir) p.references_dir = a.references_dir
      if (a.references_json) p.references_json = parseJsonOrStringArg(a.references_json, 'references_json', a.references_json)
      if (a.from_primary !== undefined) p.from_primary = a.from_primary
      if (a.title) p.title = a.title
      if (a.min_rounds !== undefined) p.min_rounds = a.min_rounds
      if (a.budget_seconds !== undefined) p.budget_seconds = a.budget_seconds
      if (a.max_references !== undefined) p.max_references = a.max_references
      if (a.force !== undefined) p.force = a.force
      if (a.run_dir) p.run_dir = a.run_dir
      return p
    },
    summarize: (r) => {
      const cov = r.references?.coverage || {}
      return [
        `Blind-LIT protocol sealed: ${r.primary?.title || '?'}`,
        `- primary: ${r.primary?.source_path || '?'} (${r.primary?.format || '?'}, ${r.primary?.bytes ?? '?'} bytes) | sha256=${String(r.primary?.sha256 || '').slice(0, 16)}...`,
        `- abstract: source=${r.primary?.abstract_source || '?'} confidence=${r.primary?.abstract_confidence || '?'} chars=${r.primary?.abstract_chars ?? '?'} section=${r.primary?.abstract_section_id || '-'}`,
        r.primary?.abstract_text ? `\n--- PRIMARY ABSTRACT (the only primary content you may use) ---\n${clip(r.primary.abstract_text, 5000)}` : '',
        `- references: ${cov.total ?? 0} inventoried (read=${cov.read ?? 0}, limited=${cov.limited ?? 0}, pending=${cov.pending ?? 0}); per-reference notes are mandatory`,
        ...listLines(r.references?.items || [], (it) => `  - ${it.id} [${it.access}/${it.status}] ${clip(it.citation || '', 150)}${it.path ? ` (${it.path})` : ''}`, 20),
        `- protocol: ${r.protocol_path}`,
        `- abstract dossier: ${r.abstract_path}`,
        r.run_dir ? `- run_dir: ${r.run_dir}` : '',
        (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
        `next: ${(r.next_steps || []).join(' | ')}`,
      ]
        .filter(Boolean)
        .join('\n')
    },
  },

  {
    name: 'bma_blind_note',
    description:
      'Record one reference reading note in BLIND-LIT mode. EVERY inventoried reference needs a note. Each claim must carry a verbatim quote; the tool extracts the reference text and verifies the quote (whitespace/typographic normalization), so paraphrased or fabricated quotes are rejected with the failed quotes listed.\n\nnote_json fields: depth ("full_text"|"abstract_only"|"citation_only"); claims:[{kind:"mechanism"|"parameter"|"condition"|"method"|"negative"|"review"|"background", claim (>=15 chars), quote (>=6 chars verbatim), location?}]; relevance:{question_link (>=30 chars), modeling_use:"mechanism"|"parameter"|"constraint"|"comparison"|"background"|"none"}; optional parameters/title/year/venue/sections_read; no_modeling_content + no_modeling_content_reason (>=80 chars) when the reference genuinely has no modeling value; access_limited_reason (>=60 chars) when only a citation is available.\n\ncitation-only references (no readable file) are recorded as status=limited and must be covered by an impossible/over_budget self-check issue before stop. Returns verification counts, text path, coverage and the remaining reference ids.',
    timeoutMs: 300_000,
    method: 'blind.note',
    parameters: {
      run_dir: strParam('Run directory returned by bma_blind_start (required).', true),
      reference_id: strParam('Reference id from the inventory (e.g. R3).', true),
      note_json: jsonParam('The reading note as a JSON object (schema in the description).', true),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => ({
      run_dir: a.run_dir,
      reference_id: a.reference_id,
      note: parseJsonArg(a.note_json, 'note_json', {}),
    }),
    summarize: (r) => {
      const v = r.verification || {}
      const cov = r.coverage || {}
      return [
        `Reference note recorded: ${r.reference_id} -> ${r.status} (depth=${r.depth || '?'})`,
        `- quote verification: ${v.status || '?'} (${v.quotes_found ?? 0}/${v.quotes_checked ?? 0} found; text ${v.text_chars ?? 0} chars)`,
        v.text_path ? `- reference text: ${v.text_path}` : '',
        `- coverage: read ${cov.read ?? 0}/${cov.total ?? 0}; limited ${cov.limited ?? 0}; pending ${cov.pending ?? 0}`,
        `- remaining reference ids: ${(r.remaining_ids || []).join(', ') || 'none'}`,
        r.note_path ? `- note: ${r.note_path}` : '',
        (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
        r.next_hint ? `next: ${r.next_hint}` : '',
      ]
        .filter(Boolean)
        .join('\n')
    },
  },

  {
    name: 'bma_blind_check',
    description:
      'Blind-protocol ledger + self-check loop. Actions:\n- status: coverage, rounds, issues, whether stop is allowed (no mutation).\n- goal: record the modeling question/goal from the abstract plus >=2 success criteria (question >=40 chars).\n- references: append references (references_dir / references_json / from_primary) without touching existing notes.\n- round: append a self-check round. Requires summary (>=80 chars), >=3 checks [{name, result:"pass"|"fail"|"skipped", evidence}], and issues. Any failed check must produce an issue. Issue fields: category (evidence|coverage|units|structure|parameters|identifiability|numerics|reproduction|reporting|other), severity (P0-P3), title, detail; disposition status open|fixed|impossible|over_budget. fixed needs fix+fix_kind(model|parameter|evidence|report|method)+evidence; impossible needs reason (>=80)+why_general (>=60, why it cannot be solved in general)+evidence (>=20); over_budget needs reason+evidence+budget{spent_s,limit_s} with spent_s >= 2*limit_s. A fix_kind="model" requires changed spec hashes in round.model_specs [{name,spec_path}].\n- freeze: models [{name,spec_path,role:"primary"|"alternative"}]; hashes specs; required before stop.\n- stop: enforces the criteria (goal recorded; every reference read or covered by a closed impossible/over_budget issue; rounds >= min_rounds; zero open issues; model frozen; every impossible/over_budget justified) and writes blind/blind_summary.md for the report.\n\nReturns the ledger state and next steps.',
    timeoutMs: 300_000,
    method: 'blind.check',
    parameters: {
      run_dir: strParam('Run directory with the blind protocol (required).', true),
      action: strParam('status | goal | references | round | freeze | stop', true),
      goal_json: jsonParam('For action=goal: {question (>=40 chars), objective?, success_criteria:[>=2], out_of_scope?:[]}.'),
      round_json: jsonParam('For action=round: {summary, checks:[{name,result,evidence}], issues:[...], model_specs:[{name,spec_path,role?}], elapsed_seconds?}.'),
      models_json: jsonParam('For action=freeze: [{name, spec_path, role:"primary"|"alternative"}].'),
      references_dir: strParam('For action=references: folder to append.'),
      references_json: jsonParam('For action=references: JSON array or JSON file path to append.'),
      from_primary: boolParam('For action=references: also parse citation strings from the bibliography.'),
      verdict: strParam('For action=stop: passed | stopped_with_limits.'),
      note: strParam('For action=stop: required when verdict=stopped_with_limits (>=60 chars).'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => {
      const p = { action: a.action }
      if (a.run_dir) p.run_dir = a.run_dir
      if (a.goal_json) p.goal = parseJsonArg(a.goal_json, 'goal_json', {})
      if (a.round_json) p.round = parseJsonArg(a.round_json, 'round_json', {})
      if (a.models_json) p.models = parseJsonArg(a.models_json, 'models_json', [])
      if (a.references_dir) p.references_dir = a.references_dir
      if (a.references_json) p.references = parseJsonOrStringArg(a.references_json, 'references_json', a.references_json)
      if (a.from_primary !== undefined) p.from_primary = a.from_primary
      if (a.verdict) p.verdict = a.verdict
      if (a.note) p.note = a.note
      return p
    },
    summarize: (r) => {
      const cov = r.coverage || {}
      const iss = r.issues || {}
      const m = r.model || {}
      const lines = [
        `Blind protocol: ${r.status || '?'} (sealed=${r.sealed ?? '?'}) | ${r.primary?.title || ''}`,
        `- goal recorded: ${r.question?.recorded ? 'yes' : 'NO'}${r.question?.question ? ` :: ${clip(r.question.question, 220)}` : ''}`,
        `- references: read ${cov.read ?? 0}/${cov.total ?? 0}; limited ${cov.limited ?? 0}; pending ${cov.pending ?? 0}`,
        `- self-check rounds: ${r.rounds_completed ?? 0}/${r.min_rounds ?? '?'}; issues: total ${iss.total ?? 0}, open ${iss.open ?? 0}, fixed ${iss.fixed ?? 0}, impossible ${iss.impossible ?? 0}, over_budget ${iss.over_budget ?? 0}`,
        (iss.open_ids || []).length ? `  open ids: ${(iss.open_ids || []).join(', ')}` : '',
        `- model: frozen=${m.frozen ?? false} v${m.current ?? 0} (${m.versions ?? 0} snapshot(s))`,
        `- can_stop: ${r.can_stop ?? false}`,
        ...(r.stop_reasons || []).map((x) => `  * ${x}`),
        r.round?.number ? `- round ${r.round.number}: added [${(r.round.issues_added || []).join(', ')}], closed [${(r.round.issues_closed || []).join(', ')}], open [${(r.round.issues_open || []).join(', ')}]` : '',
        r.round?.model_specs?.length ? `  model hashes: ${r.round.model_specs.map((x) => `${x.name}:${String(x.sha256).slice(0, 12)}`).join(', ')}` : '',
        r.references_added?.added_count !== undefined ? `- references added: ${r.references_added.added_count} (total ${r.references_added.total})` : '',
        r.freeze?.version ? `- frozen v${r.freeze.version}: ${r.freeze.primary_spec} sha=${String(r.freeze.primary_sha256 || '').slice(0, 16)}...` : '',
        r.stop_result?.verdict ? `- stop verdict: ${r.stop_result.verdict}; summary: ${r.stop_result.summary_path}` : '',
        r.protocol_path ? `- protocol: ${r.protocol_path}` : '',
        (r.warnings || []).length ? `warnings: ${(r.warnings || []).slice(-5).join('; ')}` : '',
        `next: ${(r.next_steps || []).join(' | ')}`,
      ]
      return lines.filter(Boolean).join('\n')
    },
  },

  {
    name: 'bma_blind_reveal',
    description:
      'Finish BLIND-LIT: action="reveal" lifts the primary-paper seal ONLY after the stop criteria passed and the model is frozen, then ingests the full primary text/figures for comparison. action="compare" records the frozen model vs the paper model and writes blind/model_comparison.{json,md} for the report.\n\ncomparison_json for action=compare: {dimensions:[{key, agent, paper, agreement:"match"|"partial"|"diverge"|"not_comparable", evidence, gap, follow_up}], verdict:"close"|"partial"|"diverge"|"not_comparable", summary (>=100 chars), limitations?}. All 8 dimensions are mandatory: question, model_class, state_variables, mechanisms, parameters, assumptions, behavior, evidence_use. partial/diverge dimensions need follow_up (>=10 chars).\n\nUse reveal only when the modeling + self-check are finished; reading the primary before reveal violates the protocol.',
    timeoutMs: 600_000,
    method: 'blind.reveal',
    parameters: {
      run_dir: strParam('Run directory with the blind protocol (required).', true),
      action: strParam('reveal | compare', true),
      comparison_json: jsonParam('For action=compare: the 8-dimension comparison object.'),
      reason: strParam('For action=reveal: optional reason for unblinding (recorded in the protocol).'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => {
      const p = { action: a.action, run_dir: a.run_dir }
      if (a.comparison_json) p.comparison = parseJsonArg(a.comparison_json, 'comparison_json', {})
      if (a.reason) p.reason = a.reason
      return p
    },
    summarize: (r) => {
      if (r.action === 'reveal') {
        return [
          `Primary paper unsealed at ${r.revealed_at}.`,
          `- title: ${r.primary?.title || '?'} | doc: ${r.primary?.doc_id || '?'} | chars: ${r.primary?.char_count ?? '?'}`,
          `- full text (NOW allowed): ${r.primary?.text_path || '?'}`,
          `- sections: ${r.primary?.sections_path || '?'}`,
          r.primary?.figures_path ? `- figures: ${r.primary.figures_path} (${r.primary.figure_count ?? '?'})` : '',
          `- frozen model: v${r.model_version ?? '?'}`,
          r.message ? `- ${r.message}` : '',
          (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
        ]
          .filter(Boolean)
          .join('\n')
      }
      return [
        `Model comparison recorded: ${r.verdict || '?'} (${r.dimensions ?? 0} dimensions)`,
        `- comparison: ${r.comparison_path || '?'}`,
        `- comparison JSON: ${r.comparison_json_path || '?'}`,
        r.summary ? `- summary: ${clip(r.summary, 1200)}` : '',
        `next: ${(r.next_steps || []).join(' | ')}`,
      ]
        .filter(Boolean)
        .join('\n')
    },
  },

  {
    name: 'bma_model_validate',
    description:
      'Validate and normalize a bma.modelSpec.v1 JSON model specification with MATLAB. This is the mandatory quality gate before any simulation or fit. Checks: required fields and ids, unique ids, rate-law parameter/species references, stoichiometry species, unit strings (against the knowledge-base unit vocabulary), numeric value/bounds consistency, output expressions, optional evidence format. Returns structured errors with codes, JSON paths and fix hints, plus the normalized spec written to <run_dir>/models/<name>/spec.json. Loop on this tool until valid=true.\n\nInput: pass spec_path (preferred; write the JSON with the file tools) or spec_json (JSON string).',
    timeoutMs: 180_000,
    method: 'spec.validate',
    parameters: {
      spec_path: strParam('Path to the model spec JSON (relative to work_dir or absolute).'),
      spec_json: strParam('Alternatively the full spec as a JSON string.'),
      run_dir: strParam('Run directory; the normalized spec is written under it. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => specParams(a),
    summarize: (r) => {
      const head = r.valid ? 'VALID' : `INVALID (${r.n_errors} error(s))`
      const errs = listLines(r.errors || [], (e) => `- ${e.code} at ${e.path}: ${e.message}\n    hint: ${e.hint || ''}`, 15)
      const warns = listLines(r.warnings || [], (w) => `- ${w.code} at ${w.path}: ${w.message}`, 10)
      const sum = r.summary || {}
      return [
        `Model spec validation: ${head}`,
        sum.name ? `- model: ${sum.name} (${sum.n_species} species, ${sum.n_parameters} params, ${sum.n_estimated_parameters} estimated, ${sum.n_reactions} reactions)` : '',
        r.units_check
          ? (r.units_check.applicable === false
            ? `- units: not applicable (${r.units_check.reason || r.units_check.note || 'not checked'})`
            : `- units: ok=${r.units_check.ok} checked=${r.units_check.n_units_checked}`)
          : '',
        r.conservation ? `- conservation: ${r.conservation.n_laws} independent law(s)` : '',
        r.spec_path ? `- normalized spec: ${r.spec_path}` : '',
        r.run_dir ? `- run_dir: ${r.run_dir}` : '',
        errs.length ? `errors:\n${errs.join('\n')}` : '',
        warns.length ? `warnings:\n${warns.join('\n')}` : '',
      ]
        .filter(Boolean)
        .join('\n')
    },
  },

  {
    name: 'bma_model_analyze',
    description:
      'Structural analysis of a validated model with MATLAB: stoichiometric matrix, conservation laws (moiety conservation with expressions), steady states, Jacobian eigenvalues and local stability at each steady state, dimensional check, plus modeling notes. Use it to interpret the mechanism (e.g. "E+ES is conserved", "the positive steady state is stable") and to justify or falsify candidate structures before fitting.\n\nSymbolic steady-state solving is now difficulty-gated: models with more than symbolic_max_states (default 6) or a high static nonlinearity score skip solve/vpasolve and fall back to bounded multi-start numerical steady states + numerical Jacobian. The result reports symbolic.skipped/reason/analysis_mode, so a numeric fallback is explicit rather than a silent hang. Force a symbolic attempt with options.symbolic="on" only for small models.',
    timeoutMs: 600_000,
    method: 'model.analyze',
    parameters: {
      spec_path: strParam('Path to the model spec JSON (validated).', true),
      options_json: jsonParam('Optional JSON: {substitute_guards:true, symbolic:"auto"|"on"|"off", symbolic_max_states:6, symbolic_max_score:12, numeric_budget_seconds:120, multistart:12}.'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => ({ ...specParams(a), options: parseJsonArg(a.options_json, 'options_json', {}) }),
    summarize: (r) => [
      `Model structure analysis`,
      r.analysis_mode ? `- mode: ${r.analysis_mode}` : '',
      r.symbolic && r.symbolic.skipped
        ? `- symbolic steady state: SKIPPED (${r.symbolic.reason})`
        : (r.symbolic && r.symbolic.attempted ? `- symbolic steady state: attempted (${fmtNumber((r.symbolic.elapsed_ms || 0) / 1000, 2)} s)` : ''),
      r.symbolic && r.symbolic.complexity
        ? `- symbolic complexity: score=${r.symbolic.complexity.score ?? '?'} states=${r.symbolic.complexity.n_states ?? '?'} (max_states=${r.symbolic.max_states ?? '?'}, max_score=${r.symbolic.max_score ?? '?'})`
        : '',
      r.numeric && r.numeric.stopped_early ? `- numeric search: stopped at ${r.numeric.budget_seconds}s budget` : '',
      r.dimensional_ok !== undefined ? `- dimensional consistency: ${r.dimensional_ok}` : '',
      `- conservation laws (${(r.conservation_laws || []).length}):`,
      ...listLines(r.conservation_laws || [], (c) => `  - ${typeof c === 'string' ? c : c.expression || JSON.stringify(c)}`),
      `- steady states (${(r.steady_states || []).length}):`,
      ...listLines(r.steady_states || [], (s) => {
        const values = s.values ? JSON.stringify(s.values) : JSON.stringify(s)
        return `  - ${values} stable=${s.stability ?? s.stable ?? '?'}${s.eigenvalues ? ` eigenvalues=${clip(JSON.stringify(s.eigenvalues), 200)}` : ''}`
      }, 8),
      r.guard_substitution && r.guard_substitution.stripped && r.guard_substitution.stripped.length
        ? `guard substitution: ${r.guard_substitution.stripped.length} numeric min/max guard(s) stripped for symbolic analysis`
        : '',
      (r.notes || []).length ? `notes: ${(r.notes || []).join('; ')}` : '',
      (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
      r.analysis_path ? `- analysis JSON: ${r.analysis_path}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
    ]
      .filter(Boolean)
      .join('\n'),
  },

  {
    name: 'bma_model_simulate',
    description:
      'Simulate a validated ODE model with MATLAB (ode15s/ode45). Use it to check that the model reproduces the qualitative behavior reported in the literature (trends, amplitudes, periods, steady states) before estimating parameters. Options are JSON: {time_end, n, initial_overrides:{speciesId:number}, param_overrides:{paramId:number}, solver:"ode15s"|"ode45", rtol, atol, mass_matrix:[[...]], plots:["timeseries","phase","phase3d"], phase_x, phase_y, phase_z}. A non-empty mass_matrix runs a linear-implicit DAE (ode15s with Mass/MassSingular; initial values must satisfy algebraic constraints).\n\nFor any two-state/two-output model the tool also emits a phase portrait automatically; the last closed cycle is highlighted as the limit cycle. phase_x/phase_y/phase_z may name species ids (not only output ids); request plots:["phase3d"] for a 3D projection. Returns: per-output final/min/max values, full time-series CSV path, figure paths, and warnings (negative concentrations, solver issues).',
    timeoutMs: 900_000,
    method: 'model.simulate',
    parameters: {
      spec_path: strParam('Path to the model spec JSON (validated).', true),
      options_json: jsonParam('Optional JSON object with simulation options (time_end, n, initial_overrides, param_overrides, solver, mass_matrix, plots, phase_x, phase_y, phase_z).'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => ({
      ...specParams(a),
      options: parseJsonArg(a.options_json, 'options_json', {}),
    }),
    summarize: (r) => [
      `Simulation ${r.sim_id || ''} finished.`,
      r.time ? `- time window: ${fmtNumber(r.time.t0)} → ${fmtNumber(r.time.t1)} (${r.time.n} points)` : '',
      r.timeseries_path ? `- time series CSV (states + outputs): ${r.timeseries_path}` : '',
      r.series_columns ? `- CSV columns: ${r.series_columns.join(', ')}` : '',
      `- state final values: ${JSON.stringify(r.final || {})}`,
      r.outputs_final ? `- output final values: ${JSON.stringify(r.outputs_final)}` : '',
      ...listLines((r.oscillation || []).filter((m) => m.oscillation_exists), (m) => `- oscillation ${m.id}: period=${fmtNumber(m.period)} amplitude=${fmtNumber(m.amplitude)} min=${fmtNumber(m.min)} max=${fmtNumber(m.max)}`, 8),
      `- range: ${JSON.stringify(r.min || {})} .. ${JSON.stringify(r.max || {})}`,
      r.figures ? `- figures: ${JSON.stringify(r.figures)}` : '',
      (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
    ]
      .filter(Boolean)
      .join('\n'),
  },

  {
    name: 'bma_model_simulate_cases',
    description:
      'Simulate several scenarios of one model in a single MATLAB call, e.g. parameter sweeps or knockouts from the paper. cases_json is a JSON array of objects {name, time_overrides:{end,n}, initial_overrides:{...}, param_overrides:{...}}. Returns per-case summaries and a comparison figure path.',
    timeoutMs: 1_200_000,
    method: 'model.simulate_cases',
    parameters: {
      spec_path: strParam('Path to the model spec JSON (validated).', true),
      cases_json: jsonParam('JSON array of scenarios, e.g. [{"name":"WT"},{"name":"KO","param_overrides":{"kcat":0}}].', true),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => ({
      ...specParams(a),
      cases: parseJsonArg(a.cases_json, 'cases_json', []),
    }),
    summarize: (r) => [
      `Scenario comparison finished (${r.n_cases ?? (r.cases || []).length} cases).`,
      ...listLines(r.cases || [], (c) => `- ${c.name || '?'}: final=${JSON.stringify(c.final || {})}`),
      (r.cases || []).length > 12 ? `... (${(r.cases || []).length - 12} more; full CSV: ${r.cases_summary_path || r.cases_path || 'n/a'})` : '',
      r.cases_summary_path ? `- full summary CSV: ${r.cases_summary_path}` : '',
      r.comparison_figure ? `- comparison figure: ${JSON.stringify(r.comparison_figure)}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
    ]
      .filter(Boolean)
      .join('\n'),
  },

  {
    name: 'bma_pde_simulate',
    description:
      'Solve a PDE natively with MATLAB PDE Toolbox (geometry -> mesh -> coefficients -> boundary conditions -> solvepde), without MOL/ODE expansion. Use this when the model is genuinely 2D/3D or irregular/field output is needed and the budget allows; use bma_model_simulate for 1D slab/cylinder/sphere or when you need fit/identifiability on a state-vector model.\n\nSpec: kind="pde", pde.dim=2|3, pde.domain.geometry="rectangle"|"circle"|"polygon" for 2D, "box" for 3D, or "stl" with pde.domain.file; pde.diffusion, pde.bc, optional pde.probes and pde.mesh. options_json: {steady:false, n, time_end, max_dof, max_seconds, mesh:{hmax,hgrad}, probes:[...]}. Returns PDE solution metadata, probe time series, field max/min/mean/integral, CSV, figures, and budget/warnings. Parameter fitting/identifiability still use the MOL ODE model; do not call this for 1D just to avoid MOL when fit is needed.',
    timeoutMs: 1_800_000,
    method: 'pde.simulate',
    parameters: {
      spec_path: strParam('Path to the kind="pde" / pde.dim=2 spec JSON.', true),
      options_json: jsonParam('Optional JSON: {steady, n, time_end, max_dof, max_seconds, mesh:{hmax,hgrad}, probes:[{id,species,x,y}]}.'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => ({
      ...specParams(a),
      options: parseJsonArg(a.options_json, 'options_json', {}),
    }),
    summarize: (r) => [
      `PDE Toolbox solve: ${r.success ? 'success' : 'failed'}.`,
      `- mesh: ${r.stats?.nodes ?? '?'} nodes / ${r.stats?.elements ?? '?'} elements; elapsed=${fmtNumber(r.stats?.elapsed_s, 2)} s${r.stats?.steady ? '; steady' : ''}`,
      `- geometry: ${r.pde?.geometry ?? '?'}; max_dof=${r.stats?.max_dof ?? '?'}`,
      `- probes: ${(r.probes || []).length}`,
      ...listLines(r.probes || [], (p) => `  - ${p.id} (${p.species}) final=${fmtNumber(p.values?.[p.values.length - 1])} [${p.unit || '?'}] nearest_node=${p.nearest_node ?? '?'}`, 12),
      ...listLines(r.field_stats || [], (s) => `  - field ${s.species}: final mean=${fmtNumber(s.mean?.[s.mean.length - 1])} max=${fmtNumber(s.max?.[s.max.length - 1])} integral=${fmtNumber(s.integral?.[s.integral.length - 1])}`, 8),
      r.timeseries_rel || r.timeseries_path ? `- CSV: ${r.timeseries_rel || r.timeseries_path}` : '',
      (r.figures_rel || r.figures || []).length ? `- figures: ${JSON.stringify(r.figures_rel || r.figures)}` : '',
      (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
      'For fitting/identifiability, use a 1D MOL spec (bma_model_fit) or generate a reduced observation model.',
    ].filter(Boolean).join('\n'),
  },

  {
    name: 'bma_advanced_solve',
    description:
      'Run advanced MATLAB capabilities that are not native bma.modelSpec kinds. Methods: system_id (identify a black-box linear model from CSV with System Identification Toolbox: tfest/ssest/arx), symbolic (closed-form ODE solution with dsolve/Symbolic Toolbox), sde (Euler-Maruyama stochastic simulation with drift/diffusion expressions), ssa (exact Gillespie direct-method stochastic simulation from expression propensities). This is a forward/analysis path, not a parameter-fit/identifiability model; report figures/CSV via bma_report_build extra_sections or present.\n\nproblem_json examples: system_id {data_csv, time_column:"time", output_column:"y", input_columns:["u"], model:"tfest", np:2}; symbolic {equations:["diff(x,t)=a*x"], variables:["x(t)"], conditions:["x(0)=1"]}; sde {variables:[{id:"x",initial:{value:1}}], parameters:[...], drift:"-x", diffusion:"0.1*x", time_end:10, n:1001, paths:20}; ssa {variables:[{id:"x",initial:{value:0}}], parameters:[{id:"kb",value:{value:5}},{id:"kd",value:{value:1}}], reactions:[{id:"birth",stoichiometry:{x:1},rate:{expression:"kb"}},{id:"death",stoichiometry:{x:-1},rate:{expression:"kd*x"}}], time_end:20, n:101, paths:50}. Returns method-specific fields, fit/flows, figure/artifact paths and warnings.',
    timeoutMs: 1_200_000,
    method: 'advanced.solve',
    parameters: {
      method: strParam('Advanced method: "system_id" | "symbolic" | "sde".', true),
      problem_json: jsonParam('Method-specific problem object (see tool description).', true),
      options_json: jsonParam('Optional JSON object (run_dir/work_dir are supplied by the bridge).'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => ({
      method: a.method,
      problem: parseJsonArg(a.problem_json, 'problem_json', {}),
      options: parseJsonArg(a.options_json, 'options_json', {}),
    }),
    summarize: (r) => {
      if (r.method === 'symbolic') {
        return [
          'Symbolic solution (dsolve):',
          `- variables: ${(r.variables || []).join(', ')}`,
          `- conditions: ${(r.conditions || []).join(', ') || '(none)'}`,
          `- solution: ${clip(r.solution || '', 1200)}`,
        ].filter(Boolean).join('\n')
      }
      if (r.method === 'system_id') {
        return [
          `System identification (${r.model_type || '?'}): fit=${fmtNumber(r.fit_percent, 2)}% on ${r.n_samples ?? '?'} samples`,
          `- time step: ${fmtNumber(r.time_step)} s`,
          r.figure ? `- figure: ${r.figure}` : '',
          r.summary || '',
        ].filter(Boolean).join('\n')
      }
      if (r.method === 'sde' || r.method === 'ssa') {
        const label = r.method === 'ssa' ? 'SSA (Gillespie direct)' : 'SDE (Euler-Maruyama)'
        return [
          `${label}: ${r.paths ?? '?'} paths, ${r.t?.length ?? '?'} steps`,
          ...listLines(r.species || [], (s, i) => `  - ${s}: mean_end=${fmtNumber(r.mean?.[r.mean.length - 1]?.[i])} std_end=${fmtNumber(r.std?.[r.std.length - 1]?.[i])}`, 8),
          r.summary || '',
        ].filter(Boolean).join('\n')
      }
      return `${r.summary || 'Advanced solve finished.'}`
    },
  },

  {
    name: 'bma_model_fit',
    description:
      'Estimate model parameters from experimental data with MATLAB (bounded multi-start least squares, lsqnonlin with fmincon fallback). data_csv must have a first "time" column and one column per observed output; output_map_json maps spec output ids to CSV column names, e.g. {"P_obs":"P_obs"}. options_json: {params_to_fit:["k1",...], multistart:8, max_iter:200, weights:[...], param_bounds:{id:[lb,ub]}, time_unit}. Fixed parameters keep their spec values.\n\nReturns: fitted parameters with standard errors and 95% CIs, fit metrics (R², RMSE, NRMSE, AICc, BIC, loglik), predictions/residuals CSVs, fitted spec path, figures, and warnings (local minima, ill-conditioning). Use bma_model_identifiability afterwards — individual parameters of a lumped model may not be identifiable even with an excellent fit.',
    timeoutMs: 1_800_000,
    method: 'fit.estimate',
    parameters: {
      spec_path: strParam('Path to the validated model spec JSON.', true),
      data_csv: strParam('Path to the data CSV (relative to work_dir or absolute).', true),
      output_map_json: jsonParam('JSON object mapping spec output ids to CSV columns, e.g. {"P_obs":"P_obs"}.', true),
      options_json: jsonParam('Optional JSON object with estimation options (params_to_fit, multistart, max_iter, weights).'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => ({
      ...specParams(a),
      data_csv: a.data_csv,
      output_map: parseJsonArg(a.output_map_json, 'output_map_json', {}),
      options: parseJsonArg(a.options_json, 'options_json', {}),
    }),
    summarize: (r) => [
      `Parameter estimation finished (fit ${r.fit_id || ''}).`,
      `- metrics: ${summariseMetrics(r.metrics || {})}`,
      `- parameters (all):`,
      ...summariseParams(r.params || [], 50),
      r.solver_info
        ? (Array.isArray(r.solver_info)
            ? `- multistart: ${r.solver_info.length} starts, converged=${r.solver_info.filter((x) => x && x.converged).length}, seconds=${Math.round((r.solver_info.reduce((a, x) => a + (x.seconds || 0), 0)) * 10) / 10}`
            : `- multistart: starts=${r.solver_info.n_starts ?? '?'}, seconds=${r.solver_info.seconds ?? '?'}`)
        : '',
      r.fitted_spec_path ? `- fitted spec: ${r.fitted_spec_path}` : '',
      r.fit_result_path ? `- fit result: ${r.fit_result_path}` : '',
      r.figures ? `- figures: ${JSON.stringify(r.figures)}` : '',
      (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
    ]
      .filter(Boolean)
      .join('\n'),
  },

  {
    name: 'bma_model_identifiability',
    description:
      'Assess structural and practical identifiability of model parameters with MATLAB: sensitivity-matrix rank and null-space parameter combinations, Fisher information, parameter correlation matrix and condition number, optional profile likelihood for one parameter. Run this after (or instead of) fitting to report honestly which parameters are constrained by the data and which are only identifiable as combinations. Optionally pass data_csv + output_map_json for data-based (practical) identifiability.',
    timeoutMs: 1_800_000,
    method: 'fit.identifiability',
    parameters: {
      spec_path: strParam('Path to the validated model spec JSON.', true),
      data_csv: strParam('Optional data CSV for practical identifiability.'),
      output_map_json: jsonParam('Optional JSON object mapping output ids to data columns.'),
      options_json: jsonParam('Optional JSON object with options (e.g. {"param":"kcat"} for a profile-likelihood check).'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => {
      const p = specParams(a)
      if (a.data_csv) p.data_csv = a.data_csv
      if (a.output_map_json) p.output_map = parseJsonArg(a.output_map_json, 'output_map_json', {})
      p.options = parseJsonArg(a.options_json, 'options_json', {})
      return p
    },
    summarize: (r) => [
      `Identifiability analysis`,
      `- structural: ${JSON.stringify(r.structural || {}).slice(0, 1500)}`,
      `- practical: ${JSON.stringify(r.practical || {}).slice(0, 1500)}`,
      r.correlations ? `- correlations: ${clip(JSON.stringify(r.correlations), 1200)}` : '',
      r.table_path ? `- table: ${r.table_path}` : '',
      r.profile ? `- profile likelihood: ${JSON.stringify({param: r.profile.param, ci: r.profile.ci, path: r.profile.path})}` : '',
      r.profile_requested && !r.profile ? `- profile requested but not produced: ${r.profile_reason || 'unknown'}` : '',
      (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
    ]
      .filter(Boolean)
      .join('\n'),
  },

  {
    name: 'bma_model_sensitivity',
    description:
      'Global and local parameter sensitivity with MATLAB: first-order Sobol indices, total-effect indices, and local elasticity coefficients for the chosen outputs. Use it to rank which parameters dominate model behavior, to design experiments, and to explain which literature measurements matter most. params_json/outputs_json optionally subset parameter ids and output ids.',
    timeoutMs: 1_200_000,
    method: 'fit.sensitivity',
    parameters: {
      spec_path: strParam('Path to the validated model spec JSON.', true),
      params_json: jsonParam('Optional JSON array of parameter ids to analyse, e.g. ["kf","kcat"].'),
      outputs_json: jsonParam('Optional JSON array of output ids to analyse.'),
      method: strParam('Sensitivity method: "local" (default) or "sobol"/"both" (explicit; can be expensive on stiff models).'),
      options_json: jsonParam('Optional JSON: {sobol_n, force, budget_seconds, max_seconds, seed}. Sobol runs are budget-checked; >budget is skipped unless force=true.'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => {
      const p = specParams(a)
      if (a.params_json) p.params = parseJsonArg(a.params_json, 'params_json', [])
      if (a.outputs_json) p.outputs = parseJsonArg(a.outputs_json, 'outputs_json', [])
      if (a.method) p.method = a.method
      p.options = parseJsonArg(a.options_json, 'options_json', {})
      return p
    },
    summarize: (r) => [
      `Sensitivity analysis (${r.method || r.methods || 'n/a'})`,
      r.budget
        ? `- budget: estimated=${fmtNumber(r.budget.estimated_seconds, 1)}s actual=${fmtNumber(r.budget.actual_seconds, 1)}s N=${r.budget.sobol_n ?? 'n/a'} samples=${r.budget.executed_samples ?? 'n/a'}/${r.budget.sample_count ?? 'n/a'}`
        : '',
      r.skipped ? `- SKIPPED: ${r.skip_reason || 'budget exceeded'}` : '',
      r.cancelled ? '- CANCELLED (partial result)' : '',
      r.budget && r.budget.partial && !r.cancelled ? '- PARTIAL: wall-clock limit reached' : '',
      r.indices ? `- indices: ${clip(JSON.stringify(r.indices), 3000)}` : '',
      r.table_path ? `- table: ${r.table_path}` : '',
      r.figure ? `- figure: ${JSON.stringify(r.figure)}` : '',
      (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
    ]
      .filter(Boolean)
      .join('\n'),
  },

  {
    name: 'bma_model_selection',
    description:
      'Compare candidate model structures on the same data with MATLAB (fit each, then AICc/BIC weights). candidates_json is a JSON array of {name, spec_path, data_csv?, output_map?}; a shared data_csv/output_map is used when the candidate omits them. options_json: {multistart, max_iter, candidate_seconds (default 300)}. Each candidate has an independent time budget; a slow failed candidate is marked in candidate_status and completed rows are written to model_selection.partial.json. Returns the comparison table, AICc weights, candidate status/partial path and the best model. Use it to choose between competing mechanisms instead of reporting only one.',
    timeoutMs: 2_400_000,
    method: 'validate.model_selection',
    parameters: {
      candidates_json: jsonParam('JSON array: [{"name":"m1","spec_path":"path/spec.json"}, ...].', true),
      data_csv: strParam('Shared data CSV for all candidates.'),
      output_map_json: jsonParam('Shared output map JSON object.'),
      options_json: jsonParam('Optional JSON object with fitting options for all candidates.'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => {
      const p = { candidates: parseJsonArg(a.candidates_json, 'candidates_json', []) }
      if (a.data_csv) p.data_csv = a.data_csv
      if (a.output_map_json) p.output_map = parseJsonArg(a.output_map_json, 'output_map_json', {})
      if (a.options_json) p.options = parseJsonArg(a.options_json, 'options_json', {})
      return p
    },
    summarize: (r) => [
      `Model selection finished.`,
      r.best ? `- best model: ${r.best}` : '',
      `- comparison table:`,
      ...listLines(r.table || [], (row) => `  - ${row.name}: AICc=${fmtNumber(row.aicc)} BIC=${fmtNumber(row.bic)} R²=${fmtNumber(row.r2)} weight=${fmtNumber(row.aicc_weight)}`),
      (r.candidate_status || []).some((c) => c.status !== 'ok')
        ? `- candidate status: ${(r.candidate_status || []).map((c) => `${c.name}=${c.status}${c.status === 'failed' ? `(${clip(c.error, 100)})` : ''}`).join('; ')}`
        : '',
      r.partial_path ? `- partial results: ${r.partial_path}` : '',
      r.table_path ? `- table: ${r.table_path}` : '',
      (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
    ]
      .filter(Boolean)
      .join('\n'),
  },

  {
    name: 'bma_model_validate_fit',
    description:
      'Validate a fitted model with MATLAB: k-fold time-series cross-validation (train/test R², RMSE) and residual diagnostics (normality, lag-1 autocorrelation, heteroscedasticity), with an optional figure. Use it before claiming the model is validated; report the numbers in the final report.',
    timeoutMs: 1_800_000,
    method: 'validate.cross_validation',
    parameters: {
      spec_path: strParam('Path to the validated model spec JSON.', true),
      data_csv: strParam('Data CSV used for fitting.', true),
      output_map_json: jsonParam('JSON object mapping output ids to CSV columns.', true),
      k: numParam('Number of folds, default 5.'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => ({
      ...specParams(a),
      data_csv: a.data_csv,
      output_map: parseJsonArg(a.output_map_json, 'output_map_json', {}),
      k: a.k ?? 5,
    }),
    summarize: (r) => [
      `Cross-validation / residual validation`,
      `- folds: ${JSON.stringify(r.folds || []).slice(0, 2000)}`,
      r.summary ? `- summary: ${JSON.stringify(r.summary)}` : '',
      r.figure ? `- figure: ${JSON.stringify(r.figure)}` : '',
      (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
    ]
      .filter(Boolean)
      .join('\n'),
  },

  {
    name: 'bma_report_build',
    description:
      'Build the final reproducible modeling report with MATLAB: a self-contained HTML report (embedded CSS and images), a Markdown copy, and a machine-readable model card. The report includes the model equations, parameter table with units/CI/evidence type and citations, assumptions, methods, parameter estimation and identifiability findings, validation metrics, residual figures, simulation figures, references, limitations, and the reproduction commands.\n\nCall it at the end of a run with spec_path (required) and optionally fit_result_path / analysis_path. This is the main deliverable presented to the user.',
    timeoutMs: 1_200_000,
    method: 'report.build',
    parameters: {
      spec_path: strParam('Path to the model spec JSON (required).', true),
      fit_result_path: strParam('Optional fit result JSON path (from bma_model_fit).'),
      analysis_path: strParam('Optional analysis JSON path (from bma_model_analyze).'),
      title: strParam('Report title (Chinese or English).', true),
      references_json: jsonParam('Optional JSON array of references [{citation, doi?}] used in the report.'),
      extra_sections_json: jsonParam('Optional JSON array of extra sections [{title, markdown}] to append; Markdown bodies are rendered into report.md and report.html. A file path is also accepted.'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => {
      const p = specParams(a)
      p.title = a.title
      if (a.fit_result_path) p.fit_result_path = a.fit_result_path
      if (a.analysis_path) p.analysis_path = a.analysis_path
      if (a.references_json) p.references = parseJsonArg(a.references_json, 'references_json', [])
      if (a.extra_sections_json) p.extra_sections = parseJsonOrStringArg(a.extra_sections_json, 'extra_sections_json', a.extra_sections_json)
      return p
    },
    summarize: (r) => [
      `Report built.`,
      r.report_html ? `- report HTML: ${r.report_html}` : '',
      r.report_md ? `- report Markdown: ${r.report_md}` : '',
      r.model_card_path ? `- model card: ${r.model_card_path}` : '',
      r.run_dir ? `- run_dir: ${r.run_dir}` : '',
      (r.warnings || []).length ? `warnings: ${(r.warnings || []).join('; ')}` : '',
      `Present the HTML report to the user with the present tool and summarize key findings.`,
    ]
      .filter(Boolean)
      .join('\n'),
  },

  {
    name: 'bma_codegen',
    description:
      'Export a validated model as standalone MATLAB code: a reusable ODE right-hand-side function (plus a runnable demo script) written under the run directory, and optionally a SimBiology model project (.sbproj) built from the same spec. Use it to hand the user editable MATLAB artifacts beyond the report.',
    timeoutMs: 600_000,
    method: 'codegen.model',
    parameters: {
      spec_path: strParam('Path to the model spec JSON.', true),
      simbiology: boolParam('Also export a SimBiology model (.sbproj) when the MATLAB call supports it.'),
      run_dir: strParam('Run directory. Omit to create a new run.'),
      work_dir: strParam('Optional work directory override.'),
    },
    outputSchema: { type: 'object', additionalProperties: false, properties: { summary: { type: 'string', required: true } } },
    buildParams: (a) => specParams(a),
    summarize: (r) => [
      `MATLAB code generated.`,
      r.m_file ? `- ODE function: ${r.m_file}` : '',
      r.function_name ? `- function name: ${r.function_name}` : '',
      r.run_file ? `- demo script: ${r.run_file}` : '',
      r.model_card_path ? `- model card: ${r.model_card_path}` : '',
      r.sbproj_path ? `- SimBiology project: ${r.sbproj_path}` : '',
      r.reason ? `- note: ${r.reason}` : '',
    ]
      .filter(Boolean)
      .join('\n'),
  },
]

/** Shared spec resolution for tools that accept spec_path / spec_json. */
function specParams(a) {
  if (!a.spec_path && !a.spec_json) {
    throw new Error('either spec_path or spec_json is required')
  }
  const p = {}
  if (a.spec_path) p.spec_path = a.spec_path
  if (a.spec_json) p.spec = parseJsonArg(a.spec_json, 'spec_json', null)
  if (a.run_dir) p.run_dir = a.run_dir
  return p
}

export { parseJsonArg, clip, PROJECT_LABEL }
