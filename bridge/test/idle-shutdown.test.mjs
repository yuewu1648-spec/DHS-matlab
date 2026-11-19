#!/usr/bin/env node
/**
 * Idle backend shutdown test (0.8.3).
 *
 * Starts the real control + worker through the plugin, then verifies that
 * BMA_IDLE_SHUTDOWN_SECONDS stops both MATLAB processes without another tool
 * call. Uses a temp workspace so it never touches the session workspace.
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

process.env.BMA_IDLE_SHUTDOWN_SECONDS = '2'
const { apply } = await import('../lib/index.js')

const workDir = path.join(os.tmpdir(), `bma-idle-test-${process.pid}`)
fs.mkdirSync(workDir, { recursive: true })
const registered = []
const fakeCtx = {
  tools: { register: (definition) => { registered.push(definition); return () => {} } },
  workingDirectory: { async ensure() { return workDir } },
}
apply(fakeCtx)

const statusTool = registered.find((d) => d.name === 'matlab_status')
if (!statusTool) throw new Error('matlab_status not registered')
const status = await statusTool.execute({ work_dir: workDir }, { agent: undefined, signal: undefined })
if (!/MATLAB backend ready/.test(status.summary)) throw new Error(status.summary)

function readPid(file) {
  try {
    const state = JSON.parse(fs.readFileSync(file, 'utf8'))
    return Number(state.pid) || 0
  } catch {
    return 0
  }
}
function alive(pid) {
  if (!pid) return false
  try { process.kill(pid, 0); return true } catch { return false }
}
function findState(subdir) {
  const candidates = [
    path.join(workDir, '.bma', subdir, 'state.json'),
    path.join(workDir, '.bma', subdir, 'server', 'state.json'),
  ]
  return candidates.find((p) => fs.existsSync(p)) || ''
}
const controlPid = readPid(findState('server'))
const workerPid = readPid(findState('worker'))
if (!controlPid || !workerPid) throw new Error(`missing server pid: control=${controlPid} worker=${workerPid}`)
console.log(`started control=${controlPid} worker=${workerPid}; waiting for idle shutdown`)

let stopped = false
for (let i = 0; i < 150; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 100))
  if (!alive(controlPid) && !alive(workerPid)) { stopped = true; break }
}
if (!stopped) {
  console.error(`FAIL: still alive after idle timeout: control=${alive(controlPid)} worker=${alive(workerPid)}`)
  process.exit(1)
}
console.log('IDLE SHUTDOWN OK: control and worker exited')
