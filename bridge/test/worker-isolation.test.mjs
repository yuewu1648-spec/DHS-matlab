#!/usr/bin/env node
/**
 * 0.6.0 heavy-worker isolation test.
 *
 * Proves that:
 *   1. matlab_status starts the control server and the isolated heavy worker;
 *   2. bma_model_analyze is routed to the worker, not the control server;
 *   3. while the worker is blocked in a long builtin, control health still
 *      answers quickly (no shared single-threaded queue);
 *   4. bma_cancel hard-restarts only the worker, and the control server
 *      remains usable.
 *
 * Usage: node bridge/test/worker-isolation.test.mjs [workDir]
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { apply, isHeavyMethod } from '../lib/index.js'
import { MatlabBridge } from '../lib/bridge-client.js'

const here = path.dirname(fileURLToPath(import.meta.url))
const projectRoot = path.resolve(here, '..', '..')
const workDir = path.resolve(process.argv[2] || path.join(os.tmpdir(), `bma-worker-iso-${process.pid}`))
fs.mkdirSync(workDir, { recursive: true })

let failures = 0
function check(cond, message) {
  if (cond) console.log(`PASS: ${message}`)
  else {
    failures += 1
    console.error(`FAIL: ${message}`)
  }
}

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
apply(fakeCtx)
const names = registered.map((d) => d.name)
check(names.includes('bma_model_analyze'), 'bma_model_analyze registered')
check(isHeavyMethod('model.analyze') === true, 'model.analyze classified as heavy')
check(isHeavyMethod('spec.validate') === false, 'spec.validate stays on the control server')

const callTool = async (name, args) => {
  const definition = registered.find((d) => d.name === name)
  if (!definition) throw new Error(`tool not registered: ${name}`)
  return definition.execute(args, { agent: undefined, signal: undefined })
}

const control = new MatlabBridge({ workDir, projectRoot })
const worker = new MatlabBridge({ workDir, projectRoot, serverSubdir: 'worker/server' })

try {
  const status = await callTool('matlab_status', { work_dir: workDir })
  check(/worker:/.test(status.summary), 'matlab_status reports the worker')
  check(/worker server: idle/.test(status.summary), 'worker starts idle')
  check(!/worker: BUSY/.test(status.summary), 'worker is not falsely reported busy by its own health probe')

  const analyze = await callTool('bma_model_analyze', {
    spec_path: path.join(projectRoot, 'spec', 'examples', 'enzyme_mm.json'),
    work_dir: workDir,
  })
  check(/Model structure analysis/.test(analyze.summary), 'bma_model_analyze succeeds through the worker')

  const workerState = JSON.parse(fs.readFileSync(path.join(workDir, '.bma', 'worker', 'server', 'state.json'), 'utf8'))
  const controlState = JSON.parse(fs.readFileSync(path.join(workDir, '.bma', 'server', 'state.json'), 'utf8'))
  check(workerState.last_method === 'model.analyze', `worker handled model.analyze (got ${workerState.last_method})`)
  check(controlState.last_method !== 'model.analyze', `control did not handle model.analyze (got ${controlState.last_method})`)

  const slow = worker.call('dev.eval', { code: 'pause(20)' }, { timeoutMs: 120_000 }).catch((err) => err)
  await new Promise((resolve) => setTimeout(resolve, 1_500))
  const t0 = Date.now()
  const health = await control.health({ startIfNeeded: false, ping: true })
  const elapsed = Date.now() - t0
  check(health.ok === true, 'control health answers while worker is busy')
  check(elapsed < 10_000, `control health stays responsive while worker is busy (${elapsed} ms)`)

  const cancelled = await worker.cancel({ hard: true, graceMs: 500 })
  const slowResult = await slow
  check(cancelled.cancelled === true && cancelled.killed === true, 'worker cancel kills only the worker')
  check(cancelled.restarts_on_next_call === true, 'worker replacement is lazy (no long cancel wait)')
  check(slowResult && slowResult.code === 'BMA_CANCELLED', `blocked worker call resolves as BMA_CANCELLED (${slowResult && slowResult.code})`)

  const controlAfter = await control.health({ startIfNeeded: false, ping: true })
  check(controlAfter.ok === true, 'control server survives worker cancel')
} finally {
  try {
    await control.stop()
  } catch {}
  try {
    await worker.stop()
  } catch {}
}

console.log(failures === 0 ? 'WORKER ISOLATION OK' : `WORKER ISOLATION FAILED (${failures})`)
process.exit(failures === 0 ? 0 : 1)
