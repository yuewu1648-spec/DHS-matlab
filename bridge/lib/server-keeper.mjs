#!/usr/bin/env node
/**
 * Persistent MATLAB RPC server keeper.
 *
 * Owns exactly one `matlab -batch` server for a work directory, restarts it if
 * it dies, and keeps `.bma/server/keeper.json` fresh so the rest of the system
 * knows the shared server is intentional. Run it once per workspace from an
 * unconfined shell:
 *
 *   node bridge/lib/server-keeper.mjs --work-dir E:\matlab系统建模
 */
import fs from 'node:fs'
import path from 'node:path'
import { MatlabBridge } from './bridge-client.js'

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback
}

const workDir = path.resolve(arg('work-dir', process.cwd()))
const projectRoot = arg('project-root', '')
const pollMs = Number(arg('poll-ms', '4000'))
const serverDir = path.join(workDir, '.bma', 'server')
const keeperFile = path.join(serverDir, 'keeper.json')
const logFile = path.join(serverDir, 'keeper.log')
fs.mkdirSync(serverDir, { recursive: true })

function log(msg) {
  const line = `${new Date().toISOString()} | ${msg}\n`
  fs.appendFileSync(logFile, line)
  process.stdout.write(line)
}

const bridge = new MatlabBridge({
  workDir,
  projectRoot: projectRoot ? path.resolve(projectRoot) : undefined,
  startupTimeoutMs: 240_000,
  allowAutoStart: true,
})

fs.writeFileSync(
  keeperFile,
  JSON.stringify({ pid: process.pid, work_dir: workDir, started_at: new Date().toISOString() }, null, 2)
)
log(`keeper start pid=${process.pid} workDir=${workDir}`)

let stopping = false
async function stop() {
  if (stopping) return
  stopping = true
  log('keeper stopping')
  try {
    await bridge.stop()
  } catch (err) {
    log(`stop error: ${err.message}`)
  }
  try {
    fs.rmSync(keeperFile, { force: true })
  } catch {}
  process.exit(0)
}
process.on('SIGINT', stop)
process.on('SIGTERM', stop)
process.on('exit', () => {
  try {
    fs.rmSync(keeperFile, { force: true })
  } catch {}
})

async function main() {
  let failures = 0
  while (!stopping) {
    try {
      const state = bridge.state()
      const alive = bridge.serverAlive()
      if (!alive) {
        log('server not alive; starting/attaching')
        const st = await bridge.ensureServer()
        log(`server ready pid=${st.pid}`)
        failures = 0
      } else if (state && state.pid) {
        const hbAge = Date.now() - Date.parse(state.heartbeat || 0)
        if (Number.isFinite(hbAge) && hbAge > 600_000) {
          log(`heartbeat stale ${Math.round(hbAge / 1000)}s; restarting`)
          await bridge.restart()
          continue
        }
      }
      const st2 = bridge.state() || {}
      fs.writeFileSync(
        keeperFile,
        JSON.stringify(
          {
            pid: process.pid,
            work_dir: workDir,
            matlab_pid: st2.pid || null,
            matlab_heartbeat: st2.heartbeat || null,
            updated_at: new Date().toISOString(),
          },
          null,
          2
        )
      )
      await new Promise((r) => setTimeout(r, pollMs))
    } catch (err) {
      failures += 1
      log(`keeper error (${failures}): ${err.code || ''} ${err.message}`)
      await new Promise((r) => setTimeout(r, Math.min(30_000, 2000 * failures)))
    }
  }
}

main()
