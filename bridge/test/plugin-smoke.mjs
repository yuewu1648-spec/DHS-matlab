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
check(registered.length >= 15, `registered ${registered.length} bma_* tools (expected >= 15)`)
const names = registered.map((d) => d.name)
for (const expected of ['matlab_status', 'bma_model_validate', 'bma_report_build', 'bma_codegen']) {
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
