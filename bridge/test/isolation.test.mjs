#!/usr/bin/env node
/**
 * Workspace isolation test.
 *
 * Proves that:
 *   1. two independent session workspaces each get their own `.bma/runs`
 *      artifacts and never see the other workspace's output;
 *   2. a modeling call writes nothing into the agent installation checkout
 *      (source file SHA-256 snapshot before/after);
 *   3. the RPC refuses to write an artifact outside the session workspace
 *      (`BMA_WORKSPACE_ESCAPE`).
 *
 * Usage: node bridge/test/isolation.test.mjs
 * Exit code 0 = isolated, 1 = failure.
 */
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { MatlabBridge } from '../lib/bridge-client.js'

const here = path.dirname(fileURLToPath(import.meta.url))
const projectRoot = path.resolve(here, '..', '..')
const specPath = path.join(projectRoot, 'spec', 'examples', 'enzyme_mm.json')

let failures = 0
function check(condition, message) {
  if (condition) {
    console.log(`PASS: ${message}`)
  } else {
    console.log(`FAIL: ${message}`)
    failures += 1
  }
}

const hashDirs = ['matlab', 'bridge/lib', 'bridge/skills', 'kb', 'spec', 'docs']
const hashFiles = ['VERSION', 'CHANGELOG.md', 'bridge/package.json', 'bridge/cordis.patch.yml']

function walk(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name === '.bma' || entry.name === '.tmp') continue
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) walk(full, out)
    else if (entry.isFile()) out.push(full)
  }
}

function snapshotAgentSource() {
  const files = []
  for (const rel of hashDirs) {
    const abs = path.join(projectRoot, rel)
    if (fs.existsSync(abs)) walk(abs, files)
  }
  for (const rel of hashFiles) {
    const abs = path.join(projectRoot, rel)
    if (fs.existsSync(abs)) files.push(abs)
  }
  const snap = new Map()
  for (const file of files) {
    const digest = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
    snap.set(file, digest)
  }
  return snap
}

function diffSnapshot(before, after) {
  const changed = []
  for (const [file, hash] of before) {
    if (!after.has(file)) changed.push(`deleted:${path.relative(projectRoot, file)}`)
    else if (after.get(file) !== hash) changed.push(`modified:${path.relative(projectRoot, file)}`)
  }
  for (const file of after.keys()) {
    if (!before.has(file)) changed.push(`added:${path.relative(projectRoot, file)}`)
  }
  return changed
}

function listArtifacts(dir) {
  const runs = path.join(dir, '.bma', 'runs')
  if (!fs.existsSync(runs)) return []
  const out = []
  for (const name of fs.readdirSync(runs)) {
    const run = path.join(runs, name)
    if (fs.statSync(run).isDirectory()) out.push(name)
  }
  return out
}

const workA = fs.mkdtempSync(path.join(os.tmpdir(), 'bma-iso-a-'))
const workB = fs.mkdtempSync(path.join(os.tmpdir(), 'bma-iso-b-'))
const bridgeA = new MatlabBridge({ workDir: workA, startupTimeoutMs: 240_000 })
const bridgeB = new MatlabBridge({ workDir: workB, startupTimeoutMs: 240_000 })
const before = snapshotAgentSource()

try {
  console.log(`workspace A: ${workA}`)
  console.log(`workspace B: ${workB}`)

  const spec = JSON.parse(fs.readFileSync(specPath, 'utf8'))

  // A: validate + simulate into an explicit run dir inside workspace A.
  const va = await bridgeA.call('spec.validate', { spec, run_dir: '.bma/runs/iso-a' })
  check(va.result && va.result.valid === true, 'A: spec.validate valid=true')
  const sa = await bridgeA.call('model.simulate', { spec, run_dir: '.bma/runs/iso-a' })
  check(Boolean(sa.result && sa.result.timeseries_path), 'A: model.simulate wrote a time-series CSV')
  const runsA = listArtifacts(workA)
  check(runsA.includes('iso-a'), `A: own run created (${runsA.join(',') || 'none'})`)

  // B: default run location (auto-created) must land in workspace B only.
  const vb = await bridgeB.call('spec.validate', { spec })
  check(vb.result && vb.result.valid === true, 'B: spec.validate valid=true')
  const runsB = listArtifacts(workB)
  check(runsB.length >= 1, `B: own run created (${runsB.join(',') || 'none'})`)
  check(!runsB.includes('iso-a'), 'B: does not contain workspace A run')

  // Escape attempt: run_dir outside the workspace must be rejected and create nothing.
  const escapeTarget = path.join(workB, '.bma', 'runs', 'escaped-from-a')
  let escapeCode = ''
  try {
    await bridgeA.call('spec.validate', { spec, run_dir: escapeTarget })
  } catch (err) {
    escapeCode = err.code || ''
  }
  check(escapeCode === 'BMA_WORKSPACE_ESCAPE', `escape rejected with BMA_WORKSPACE_ESCAPE (got ${escapeCode || 'no error'})`)
  check(!fs.existsSync(escapeTarget), 'escape attempt created no directory outside the workspace')

  // Agent installation must be byte-identical.
  const after = snapshotAgentSource()
  const changed = diffSnapshot(before, after)
  check(changed.length === 0, `agent folder unchanged (${changed.length} change(s))`)
  for (const item of changed.slice(0, 10)) console.log(`       ${item}`)
} catch (err) {
  console.log(`FAIL: isolation test error: ${err.code || ''} ${err.message}`)
  failures += 1
} finally {
  try {
    await bridgeA.stop()
  } catch {}
  try {
    await bridgeB.stop()
  } catch {}
  // MATLAB's cwd is the workspace; give the OS a moment to release handles
  // before deleting the temp workspaces (best-effort; leftovers are in %TEMP%).
  for (let attempt = 0; attempt < 8; attempt += 1) {
    try {
      fs.rmSync(workA, { recursive: true, force: true })
      break
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 500))
    }
  }
  for (let attempt = 0; attempt < 8; attempt += 1) {
    try {
      fs.rmSync(workB, { recursive: true, force: true })
      break
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 500))
    }
  }
}

console.log(failures === 0 ? 'ISOLATION OK' : `ISOLATION FAILED (${failures} check(s))`)
process.exitCode = failures === 0 ? 0 : 1
