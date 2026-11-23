#!/usr/bin/env node
/**
 * Plugin smoke test without a DSH host.
 *
 * Verifies that:
 *   1. the plugin registers all bma_* tools through a fake ctx.tools;
 *   2. every tool's argument/output schema compiles (defineTool);
 *   3. a real MATLAB server spawned by the bridge answers two representative
 *      tool calls end-to-end (matlab_status, bma_model_validate).
 *
 * Usage:
 *   node bridge/test/plugin-smoke.mjs [workDir]
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { apply } from '../lib/index.js'
import { MatlabBridge } from '../lib/bridge-client.js'

const here = path.dirname(fileURLToPath(import.meta.url))
const projectRoot = path.resolve(here, '..', '..')
// Default to a temp workspace outside the agent checkout; runtime artifacts
  // must never touch the agent installation directory.
  const workDir = path.resolve(process.argv[2] || path.join(os.tmpdir(), `bma-plugin-smoke-${process.pid}`))
fs.mkdirSync(workDir, { recursive: true })

const registered = []
const fakeCtx = {
  tools: {
    register(definition) {
      registered.push(definition)
      return () => {}
    },
  },
  workingDirectory: {
    async ensure() {
      return workDir
    },
  },
}

function check(condition, message) {
  if (!condition) {
    console.error(`FAIL: ${message}`)
    process.exitCode = 1
  } else {
    console.log(`PASS: ${message}`)
  }
}

apply(fakeCtx)
check(registered.length >= 24, `registered ${registered.length} bma_* tools (expected >= 24)`)
const names = registered.map((d) => d.name)
for (const expected of ['matlab_status', 'bma_model_validate', 'bma_report_build', 'bma_codegen',
  'bma_blind_start', 'bma_blind_note', 'bma_blind_check', 'bma_blind_reveal']) {
  check(names.includes(expected), `tool ${expected} registered`)
}
for (const definition of registered) {
  const serialized = JSON.stringify(definition.parameters || {})
  check(!/"required":false/.test(serialized), `${definition.name} parameters carry no required:false`)
  check(typeof definition.execute === 'function', `${definition.name} has execute()`)
  check(definition.timeoutMs > 0, `${definition.name} declares timeoutMs`)
}

async function callTool(name, args) {
  const definition = registered.find((d) => d.name === name)
  if (!definition) throw new Error(`tool not registered: ${name}`)
  return definition.execute(args, { agent: undefined, signal: undefined })
}

const workDirArg = workDir
const status = await callTool('matlab_status', { work_dir: workDirArg })
check(/MATLAB backend ready/.test(status.summary), 'matlab_status starts/attaches the MATLAB backend')
console.log(status.summary.split('\n').map((line) => `  | ${line}`).join('\n'))

const specPath = path.join(projectRoot, 'spec', 'examples', 'enzyme_mm.json')
const validation = await callTool('bma_model_validate', { spec_path: specPath, work_dir: workDirArg })
check(/VALID/.test(validation.summary), 'bma_model_validate returns VALID for the example spec')
console.log(validation.summary.split('\n').map((line) => `  | ${line}`).join('\n'))

// Native PDE Toolbox path: 2D spec is validated without MOL expansion and
// solved through the heavy worker (pde.simulate).
const pdeSpec = path.join(projectRoot, 'tests', 'fixtures', 'upgrade', 'pde_toolbox', 'rectangle_2d.json')
const pdeValid = await callTool('bma_model_validate', { spec_path: pdeSpec, work_dir: workDirArg })
check(/VALID/.test(pdeValid.summary), 'bma_model_validate accepts a native 2D PDE spec')
const pde = await callTool('bma_pde_simulate', {
  spec_path: pdeSpec,
  options_json: JSON.stringify({ max_dof: 50000, max_seconds: 120 }),
  work_dir: workDirArg,
})
check(/PDE Toolbox solve: success/.test(pde.summary), 'bma_pde_simulate solves 2D with PDE Toolbox')
console.log(pde.summary.split('\n').map((line) => `  | ${line}`).join('\n'))

// BLIND-LIT: seal an abstract-only primary, ingest refusal, one verified note.
const blindRun = path.join(workDir, '.bma', 'runs', 'smoke-blind')
const blindPrimary = path.join(workDir, 'blind_primary.txt')
const blindRefDir = path.join(workDir, 'blind_refs')
fs.mkdirSync(blindRefDir, { recursive: true })
fs.writeFileSync(blindPrimary, [
  'Blind smoke primary',
  'Abstract',
  'We ask whether transporter abundance is controlled by phosphorylation within thirty minutes.',
  '1. Introduction',
  'SMOKE_SECRET_BODY must never be readable during blind modeling.',
  'References',
  '[1] Smith A. 2019. Transporter kinetics. J Biol 12:3-9.',
].join('\n'), 'utf8')
fs.writeFileSync(path.join(blindRefDir, 'ref1.txt'), [
  'Transporter kinetics',
  'Abstract',
  'The Km for glucose uptake was 12.5 uM in wild-type cells.',
].join('\n'), 'utf8')
const blindStart = await callTool('bma_blind_start', {
  primary_path: blindPrimary,
  references_dir: blindRefDir,
  run_dir: blindRun,
  min_rounds: 2,
  work_dir: workDirArg,
})
check(/Blind-LIT protocol sealed/.test(blindStart.summary) && /We ask whether transporter abundance/.test(blindStart.summary),
  'bma_blind_start seals the primary and exposes only the abstract')
try {
  await callTool('bma_literature_ingest', { path: blindPrimary, run_dir: blindRun, work_dir: workDirArg })
  check(false, 'bma_literature_ingest rejects the sealed primary')
} catch (err) {
  check(/BMA_SEALED/.test(String(err && err.message)), 'bma_literature_ingest rejects the sealed primary')
}
const blindNote = await callTool('bma_blind_note', {
  run_dir: blindRun,
  reference_id: 'R1',
  note_json: JSON.stringify({
    depth: 'full_text',
    claims: [{
      kind: 'parameter',
      claim: 'Glucose uptake Km is 12.5 uM in wild-type cells.',
      quote: 'Km for glucose uptake was 12.5 uM',
      location: 'Abstract',
    }],
    relevance: {
      question_link: 'Provides the kinetic constant needed to constrain the transporter model.',
      modeling_use: 'parameter',
    },
  }),
  work_dir: workDirArg,
})
check(/Reference note recorded: R1 -> read/.test(blindNote.summary), 'bma_blind_note verifies a verbatim quote')
const blindStatus = await callTool('bma_blind_check', {
  run_dir: blindRun,
  action: 'status',
  work_dir: workDirArg,
})
check(/Blind protocol: sealed/.test(blindStatus.summary), 'bma_blind_check reports the sealed protocol')
console.log(blindStatus.summary.split('\n').map((line) => `  | ${line}`).join('\n'))

const goal = await callTool('bma_blind_check', {
  run_dir: blindRun,
  action: 'goal',
  goal_json: JSON.stringify({
    question: 'How is transporter abundance regulated during nitrogen starvation, and can phosphorylation explain the thirty-minute decline?',
    objective: 'Build a falsifiable transporter-regulation model from the abstract and references.',
    success_criteria: [
      'The model reproduces the reported direction of the abundance decline within thirty minutes.',
      'The model predicts an experiment that distinguishes phosphorylation from transcriptional control.',
    ],
  }),
  work_dir: workDirArg,
})
check(/goal recorded: yes/.test(goal.summary), 'bma_blind_check records the modeling goal')
const roundArgs = {
  summary: 'Round one checks alignment, coverage, specification validity and numerical behavior; the first pass finds no blocking defect and records the results as evidence.',
  checks: [
    { name: 'alignment', result: 'pass', evidence: 'the model outputs the transporter abundance asked about in the abstract' },
    { name: 'coverage', result: 'pass', evidence: 'read 1/1 reference with a verified verbatim quote' },
    { name: 'spec', result: 'pass', evidence: 'bma_model_validate returned valid=true for the enzyme skeleton' },
  ],
}
const round1 = await callTool('bma_blind_check', {
  run_dir: blindRun,
  action: 'round',
  round_json: JSON.stringify(roundArgs),
  work_dir: workDirArg,
})
const round2 = await callTool('bma_blind_check', {
  run_dir: blindRun,
  action: 'round',
  round_json: JSON.stringify({
    ...roundArgs,
    summary: 'Round two re-checks the same dimensions after re-reading the note, adds the falsifiable prediction to the report and confirms that no open issue remains before freezing.',
  }),
  work_dir: workDirArg,
})
check(/round 2/.test(round2.summary), 'bma_blind_check appends self-check rounds')
const freeze = await callTool('bma_blind_check', {
  run_dir: blindRun,
  action: 'freeze',
  models_json: JSON.stringify([{ name: 'smoke_model', spec_path: specPath, role: 'primary' }]),
  work_dir: workDirArg,
})
check(/frozen v1/.test(freeze.summary), 'bma_blind_check freezes a validated model spec')
const stop = await callTool('bma_blind_check', {
  run_dir: blindRun,
  action: 'stop',
  verdict: 'passed',
  work_dir: workDirArg,
})
check(/stop verdict: passed/.test(stop.summary), 'bma_blind_check passes the stop criteria')
const reveal = await callTool('bma_blind_reveal', {
  run_dir: blindRun,
  action: 'reveal',
  reason: 'plugin smoke: verify the unseal path end-to-end',
  work_dir: workDirArg,
})
check(/Primary paper unsealed/.test(reveal.summary) && /full text \(NOW allowed\)/.test(reveal.summary),
  'bma_blind_reveal unseals and ingests the full primary')
const dims = [
  ['question', 'The model answers the starvation-regulation question from the abstract.', 'The paper asks how transporter abundance is regulated.'],
  ['model_class', 'A small ODE regulation model.', 'A detailed kinetic model.'],
  ['state_variables', 'Transporter abundance and phosphorylation state.', 'The paper uses several transporter species.'],
  ['mechanisms', 'Phosphorylation reduces surface abundance.', 'The paper includes phosphorylation and transcriptional control.'],
  ['parameters', 'Km taken from the reference; other values assumed.', 'The paper reports fitted parameter values.'],
  ['assumptions', 'Well-mixed, constant temperature, no spatial transport.', 'The paper includes trafficking compartments.'],
  ['behavior', 'Abundance declines within thirty minutes.', 'The paper reports a decline measured over thirty minutes.'],
  ['evidence_use', 'Only the abstract and one reference were used before unblinding.', 'The paper uses its own results and figures.'],
].map(([key, agent, paper]) => ({
  key,
  agent,
  paper,
  agreement: 'partial',
  evidence: 'smoke comparison evidence from the abstract and reference text',
  gap: 'the blind model has fewer mechanisms than the paper',
  follow_up: 'compare quantitatively after unblinding and record the remaining gap',
}))
const compare = await callTool('bma_blind_reveal', {
  run_dir: blindRun,
  action: 'compare',
  comparison_json: JSON.stringify({
    dimensions: dims,
    verdict: 'partial',
    summary: 'The blind model recovers the phosphorylation pathway from the abstract and references, but the paper adds transcriptional control and trafficking; the mechanism-level overlap is partial while the quantitative parameter ranges differ.',
    limitations: 'The smoke fixture only has one reference and a synthetic abstract.',
  }),
  work_dir: workDirArg,
})
check(/Model comparison recorded: partial \(8 dimensions\)/.test(compare.summary),
  'bma_blind_reveal records the 8-dimension comparison')

const badSpec = { ...JSON.parse(fs.readFileSync(specPath, 'utf8')) }
badSpec.parameters[0].unit = 'banana'
const bad = await callTool('bma_model_validate', { spec_json: JSON.stringify(badSpec), work_dir: workDirArg })
check(/INVALID/.test(bad.summary) && /BMA_UNIT_UNKNOWN/.test(bad.summary), 'invalid unit returns INVALID with BMA_UNIT_UNKNOWN')

try {
  await new MatlabBridge({ workDir }).stop()
} catch {}
try {
  await new MatlabBridge({ workDir, serverSubdir: 'worker/server' }).stop()
} catch {}

console.log(process.exitCode ? 'SMOKE FAILED' : 'SMOKE OK')
