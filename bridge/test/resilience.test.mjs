#!/usr/bin/env node
/**
 * Bridge resilience test for 0.5.0 (issue I1).
 *
 * Verifies that:
 *   1. a BMA_TIMEOUT is NOT retried; the stuck MATLAB process is restarted;
 *   2. health exposes last_timeout and the server is usable again;
 *   3. bma_cancel(hard=true) aborts an in-flight call and restarts the server.
 *
 * Usage: node bridge/test/resilience.test.mjs [workDir]
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { MatlabBridge } from '../lib/bridge-client.js'

const here = path.dirname(fileURLToPath(import.meta.url))
const projectRoot = path.resolve(here, '..', '..')
const workDir = path.resolve(process.argv[2] || path.join(os.tmpdir(), `bma-resilience-${process.pid}`))
fs.mkdirSync(workDir, { recursive: true })

let failures = 0
function check(cond, message) {
  if (cond) console.log(`PASS: ${message}`)
  else {
    failures += 1
    console.error(`FAIL: ${message}`)
  }
}

const bridge = new MatlabBridge({ workDir, projectRoot, startupTimeoutMs: 300_000 })
try {
  const h0 = await bridge.health({ startIfNeeded: true, ping: true })
  check(h0.ok === true && h0.server_alive === true, 'server starts and reports healthy')

  let timeoutError = null
  const t0 = Date.now()
  try {
    await bridge.call('dev.eval', { code: 'pause(20)' }, { timeoutMs: 2_500 })
  } catch (err) {
    timeoutError = err
  }
  const elapsed = Date.now() - t0
  check(Boolean(timeoutError) && timeoutError.code === 'BMA_TIMEOUT', `heavy call fails with BMA_TIMEOUT (${elapsed} ms)`)
  check(timeoutError && timeoutError.details && timeoutError.details.killed === true, 'timeout error reports the stuck process was killed')
  check(timeoutError && timeoutError.details && timeoutError.details.restarts_on_next_call === true, 'timeout replacement starts lazily on the next call')
  check(timeoutError && timeoutError.details && timeoutError.details.retried === false, 'timeout is not retried')

  const h1 = await bridge.health({ startIfNeeded: true, ping: true })
  check(h1.ok === true && h1.server_alive === true, 'server is usable after timeout recovery')
  check(Boolean(h1.status && h1.status.last_timeout), 'health reports the last timeout')

  const slow = bridge.call('dev.eval', { code: 'pause(60)' }, { timeoutMs: 120_000 }).catch((err) => err)
  await new Promise((resolve) => setTimeout(resolve, 1_500))
  const cancelResult = await bridge.cancel({ hard: true, graceMs: 1_000 })
  const slowResult = await slow
  check(cancelResult.cancelled === true && cancelResult.killed === true, 'bma_cancel kills the busy server')
  check(cancelResult.restarts_on_next_call === true, 'bma_cancel replacement starts lazily')
  check(slowResult && slowResult.code === 'BMA_CANCELLED', `in-flight call resolves as BMA_CANCELLED (${slowResult && slowResult.code})`)

  const h2 = await bridge.health({ startIfNeeded: true, ping: true })
  check(h2.ok === true && h2.server_alive === true, 'server is usable after cancel')
} finally {
  try {
    await bridge.stop()
  } catch {}
}
console.log(failures === 0 ? 'RESILIENCE OK' : `RESILIENCE FAILED (${failures})`)
process.exit(failures === 0 ? 0 : 1)
