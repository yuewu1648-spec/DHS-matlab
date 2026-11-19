/**
 * @local/dsh-bio-matlab — Cordis preset plugin.
 *
 * Registers the `bma_*` model-facing tools on `ctx.tools`. Each call resolves
 * the session working directory through the host `workingDirectory` service,
 * attaches to (or starts) the project's MATLAB JSON-RPC server for that
 * directory, and renders a compact summary for the model.
 */
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineTool } from '@deepseek-ai/dsh-tools'
import { MatlabBridge } from './bridge-client.js'
import { TOOL_SPECS } from './tools.js'
import { readAgentVersion } from './version.js'

export const name = 'bio-matlab-tools'
export const inject = ['tools', 'workingDirectory']

const pluginDir = path.dirname(fileURLToPath(import.meta.url))
const projectRoot = path.resolve(pluginDir, '..', '..')

function idleShutdownMs() {
  const raw = process.env.BMA_IDLE_SHUTDOWN_SECONDS
  const seconds = raw === undefined || raw === '' ? 300 : Number(raw)
  if (!Number.isFinite(seconds) || seconds <= 0) return 0
  return Math.min(3600, seconds) * 1000
}

const IDLE_SHUTDOWN_MS = idleShutdownMs()

/**
 * Methods that can run for an unbounded time or block a MATLAB builtin. They
 * run in the isolated worker server; the control server stays responsive for
 * matlab_status / bma_cancel / kb / run metadata (0.6.0, issue I1).
 */
const HEAVY_METHODS = new Set([
  'literature.ingest',
  'model.analyze',
  'model.simulate',
  'pde.simulate',
  'advanced.solve',
  'model.simulate_cases',
  'fit.estimate',
  'fit.profile',
  'fit.sensitivity',
  'fit.identifiability',
  'validate.model_selection',
  'validate.cross_validation',
  'validate.residuals',
  'report.build',
  'codegen.model',
  'simbiology.export',
])

export function isHeavyMethod(method) {
  return HEAVY_METHODS.has(method)
}

export function apply(ctx) {
  const agentInfo = readAgentVersion(projectRoot)
  console.error(
    `[bio-matlab] agent ${agentInfo.agentVersion} (bundle ${agentInfo.bundleVersion}, schema ${agentInfo.specSchema}) at ${projectRoot}`
  )
  /** @type {Map<string, {control: MatlabBridge, worker: MatlabBridge, key: string, active: number, timer: NodeJS.Timeout|null, stopping: boolean, stopPromise: Promise<void>|null}>} */
  const bridges = new Map()

  function clearIdleTimer(pair) {
    if (pair.timer) {
      clearTimeout(pair.timer)
      pair.timer = null
    }
  }

  function scheduleIdleShutdown(pair) {
    clearIdleTimer(pair)
    if (IDLE_SHUTDOWN_MS <= 0) return
    pair.timer = setTimeout(() => {
      pair.timer = null
      void shutdownPair(pair)
    }, IDLE_SHUTDOWN_MS)
    // Do not keep the DSH process alive solely for this timer.
    pair.timer.unref?.()
  }

  async function shutdownPair(pair) {
    if (!pair || pair.stopping) return pair?.stopPromise || undefined
    if (pair.active > 0) {
      scheduleIdleShutdown(pair)
      return undefined
    }
    pair.stopping = true
    clearIdleTimer(pair)
    pair.stopPromise = (async () => {
      try {
        await pair.worker.stop()
      } catch {}
      try {
        await pair.control.stop()
      } catch {}
      if (bridges.get(pair.key) === pair) bridges.delete(pair.key)
      console.error(`[bio-matlab] idle shutdown: MATLAB control+worker stopped for ${pair.key}`)
    })()
    return pair.stopPromise
  }

  async function bridgeFor(workDir) {
    const key = workDir.toLowerCase()
    let pair = bridges.get(key)
    if (pair && pair.stopping) {
      try {
        await pair.stopPromise
      } catch {}
      if (bridges.get(key) === pair) bridges.delete(key)
      pair = undefined
    }
    if (!pair) {
      pair = {
        key,
        active: 0,
        timer: null,
        stopping: false,
        stopPromise: null,
        control: new MatlabBridge({ workDir, projectRoot }),
        worker: new MatlabBridge({ workDir, projectRoot, serverSubdir: 'worker/server' }),
      }
      bridges.set(key, pair)
      scheduleIdleShutdown(pair)
    }
    return pair
  }

  async function resolveWorkDir(args, exec) {
    if (args && typeof args.work_dir === 'string' && args.work_dir.trim() !== '') {
      return path.resolve(args.work_dir.trim())
    }
    try {
      if (ctx.workingDirectory && exec && exec.agent) {
        const cwd = await ctx.workingDirectory.ensure(exec.agent, exec.signal)
        if (cwd) return path.resolve(String(cwd))
      }
    } catch {
      // Fall through to the project root.
    }
    return projectRoot
  }

  let registered = 0
  for (const spec of TOOL_SPECS) {
    try {
      ctx.tools.register(
        defineTool({
          name: spec.name,
          description: spec.description,
          timeoutMs: spec.timeoutMs,
          parameters: spec.parameters,
          output: {
            schema: spec.outputSchema,
            render: (_args, value) => [{ type: 'text', text: value && value.summary ? String(value.summary) : '' }],
          },
          async execute(args, exec) {
            const workDir = await resolveWorkDir(args, exec)
            const pair = await bridgeFor(workDir)
            const params = spec.buildParams ? spec.buildParams(args || {}) : {}
            const callTimeout = Math.max(60_000, spec.timeoutMs - 20_000)
            pair.active += 1
            clearIdleTimer(pair)
            try {
              // matlab_status starts/checks both servers. Health snapshots are
              // taken in parallel, so a busy worker never delays the control
              // server's response.
              if (spec.name === 'matlab_status') {
                const [control, worker] = await Promise.all([
                  pair.control.health({ startIfNeeded: true, ping: true }),
                  pair.worker.health({ startIfNeeded: true, ping: true }).catch((err) => ({
                    ok: false,
                    server_alive: false,
                    busy: false,
                    start_error: {
                      code: err.code || 'BMA_WORKER_START_FAILED',
                      message: String(err && err.message ? err.message : err),
                    },
                  })),
                ])
                return {
                  summary: spec.summarize(
                    { ...control, worker, worker_status: worker.status || null },
                    { workDir, args, agentInfo }
                  ),
                }
              }
              // bma_cancel must bypass both serialized queues; otherwise it
              // would wait for the very call it is supposed to cancel.
              if (spec.name === 'bma_cancel') {
                const cancelArgs = args || {}
                const cancelOpts = {
                  hard: cancelArgs.hard !== false,
                  graceMs: Math.max(0, Number(cancelArgs.grace_seconds ?? 3)) * 1000,
                }
                const [worker, control] = await Promise.all([
                  pair.worker.cancel(cancelOpts),
                  pair.control.cancel(cancelOpts),
                ])
                return {
                  summary: spec.summarize(
                    {
                      worker,
                      control,
                      cancelled: Boolean(worker.cancelled || control.cancelled),
                      restarted: Boolean(worker.restarted || control.restarted),
                    },
                    { workDir, args, agentInfo }
                  ),
                }
              }
              const target = isHeavyMethod(spec.method) ? pair.worker : pair.control
              const { result } = await target.call(spec.method, params, {
                timeoutMs: callTimeout,
                workDir,
              })
              return { summary: spec.summarize(result, { workDir, args, agentInfo }) }
            } catch (err) {
              const code = err.code || 'BMA_ERROR'
              const details = err.details ? `\n${JSON.stringify(err.details).slice(0, 2000)}` : ''
              throw new Error(`${code}: ${err.message}${details}`)
            } finally {
              pair.active = Math.max(0, pair.active - 1)
              if (!pair.stopping) scheduleIdleShutdown(pair)
            }
          },
        })
      )
      registered += 1
    } catch (err) {
      // One bad definition must not prevent the remaining bma_* tools from
      // mounting; surface the failure in the Host log instead.
      console.error(`[bio-matlab] tool registration failed: ${spec.name}: ${err.message}`)
    }
  }
  if (registered === 0) {
    throw new Error('[bio-matlab] no bma_* tools could be registered')
  }
  if (typeof ctx.effect === 'function') {
    ctx.effect(() => async () => {
      const pairs = [...bridges.values()]
      bridges.clear()
      await Promise.allSettled(pairs.map(async (pair) => {
        clearIdleTimer(pair)
        pair.stopping = true
        try { await pair.worker.stop() } catch {}
        try { await pair.control.stop() } catch {}
      }))
    }, 'bio-matlab MATLAB backend cleanup')
  }
  console.error(`[bio-matlab] registered ${registered}/${TOOL_SPECS.length} tools`)
  if (IDLE_SHUTDOWN_MS > 0) {
    console.error(`[bio-matlab] idle backend shutdown after ${IDLE_SHUTDOWN_MS / 1000}s without calls`)
  }
}
