/**
 * MATLAB file-based JSON-RPC bridge.
 *
 * The MATLAB side (`bma.server.start`) is a blocking `matlab -batch` process
 * that polls `<workDir>/.bma/server/inbox` and answers through `outbox`.
 * This client owns the server lifecycle: spawn, readiness, queueing, timeout,
 * crash detection/restart and graceful stop.
 *
 * No network ports and no stdout parsing: everything travels as small JSON
 * files, which survives Windows sandbox restrictions and MATLAB's buffering.
 */
import { spawn, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'

const DEFAULT_MATLAB =
  process.env.BMA_MATLAB_EXE ||
  'C:\\Program Files\\MATLAB\\R2024a\\bin\\matlab.exe'

export class BmaRpcError extends Error {
  constructor(code, message, { details, elapsedMs, id } = {}) {
    super(message)
    this.name = 'BmaRpcError'
    this.code = code
    this.details = details
    this.elapsedMs = elapsedMs
    this.rpcId = id
  }
}

function isAlive(pid) {
  if (!pid || Number.isNaN(Number(pid))) return false
  try {
    process.kill(Number(pid), 0)
    return true
  } catch (err) {
    return err.code === 'EPERM'
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function atomicWriteJson(file, value) {
  const tmp = `${file}.tmp-${crypto.randomUUID()}`
  fs.writeFileSync(tmp, JSON.stringify(value), 'utf8')
  fs.renameSync(tmp, file)
}

function readJsonSafe(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'))
  } catch {
    return null
  }
}

/** Quote a MATLAB char literal for a -batch command line. */
function matlabStr(value) {
  return `'${String(value).replace(/'/g, "''")}'`
}

export class MatlabBridge {
  /**
   * @param {object} opts
   * @param {string} opts.workDir absolute session/work directory
   * @param {string} [opts.projectRoot] repo root containing matlab/
   * @param {string} [opts.matlabExe]
   * @param {number} [opts.startupTimeoutMs]
   * @param {number} [opts.timeoutMs] default per-call timeout
   * @param {object} [opts.env]
   */
  constructor(opts = {}) {
    if (!opts.workDir) throw new Error('MatlabBridge requires workDir')
    this.workDir = path.resolve(opts.workDir)
    this.projectRoot = path.resolve(opts.projectRoot || process.env.BMA_PROJECT_ROOT || defaultProjectRoot())
    this.matlabExe = opts.matlabExe || DEFAULT_MATLAB
    this.startupTimeoutMs = opts.startupTimeoutMs ?? 300_000
    this.timeoutMs = opts.timeoutMs ?? 180_000
    this.allowAutoStart = opts.allowAutoStart ?? true
    this.env = { ...process.env, ...(opts.env || {}) }
    this.serverSubdir = normalizeServerSubdir(opts.serverSubdir || 'server')
    this.serverDir = path.join(this.workDir, '.bma', this.serverSubdir)
    this.runtimeRoot =
      this.serverSubdir === 'server'
        ? path.join(this.workDir, '.tmp')
        : path.join(this.workDir, '.tmp', this.serverSubdir.replace(/[\\/]+/g, '-'))
    this.inbox = path.join(this.serverDir, 'inbox')
    this.outbox = path.join(this.serverDir, 'outbox')
    this.done = path.join(this.serverDir, 'done')
    this.stateFile = path.join(this.serverDir, 'state.json')
    this.token = opts.token || crypto.randomBytes(16).toString('hex')
    this.child = null
    this.lastLog = ''
    this._queue = Promise.resolve()
    this._confirmed = false
    this._state = null
    // Health/diagnostics used by matlab_status and by fail-fast logic after a
    // timed-out heavy call. The MATLAB server is single-threaded, so one stuck
    // builtin can make every later RPC look like a dead server.
    this._inFlight = null
    this._queueDepth = 0
    this._lastTimeout = null
    this._lastError = null
    this._lastRestart = null
    this._restarts = 0
    this._generation = 0
    this._unhealthyUntil = 0
    this._createdAt = new Date().toISOString()
  }

  state() {
    return readJsonSafe(this.stateFile)
  }

  serverAlive() {
    const st = this.state()
    if (!st || !st.pid) return false
    if (isAlive(st.pid)) return st
    // In a restricted sandbox the pid probe may be blocked; only trust a very
    // recent heartbeat in that case so a killed server cannot stall a call for
    // the full timeout (ISS-02).
    const age = Date.now() - Date.parse(st.heartbeat || 0)
    const veryRecent = Number.isFinite(age) && age > -60_000 && age < 15_000
    return veryRecent ? st : false
  }

  /** True when state.json looks fresh enough to trust without a spawn race. */
  freshState() {
    const st = this.state()
    if (!st || !st.pid) return null
    const age = Date.now() - Date.parse(st.heartbeat || 0)
    return Number.isFinite(age) && age > -60_000 && age < 10_000 ? st : null
  }

  /** Ensure exactly one live MATLAB server for this workDir, then return it. */
  async ensureServer() {
    let fresh = this.freshState()
    if (!fresh) {
      // state.json is replaced every second; a reader can hit the rename gap.
      for (let i = 0; i < 30 && !fresh; i += 1) {
        await sleep(100)
        fresh = this.freshState()
      }
    }
    if (fresh) {
      this.token = fresh.token
      this._confirmed = true
      return fresh
    }
    const existing = this.serverAlive()
    if (existing) {
      this.token = existing.token
      this._confirmed = true
      return existing
    }
    if (this.child && this.child.exitCode === null) {
      // We are mid-spawn: wait for readiness instead of spawning twice.
      return this.waitForReady()
    }
    if (!this.allowAutoStart) {
      throw new BmaRpcError(
        'BMA_SERVER_ABSENT',
        `No live MATLAB server for ${this.workDir}. The shared keeper (bridge/lib/server-keeper.mjs) is not running; ask the operator to start it.`
      )
    }
    // Cross-process spawn lock: several callers may race for a cold server.
    const release = await this._acquireSpawnLock(path.join(this.serverDir, 'spawn.lock'))
    try {
      const again = this.freshState()
      if (again) {
        this.token = again.token
        this._confirmed = true
        return again
      }
      return await this._spawnServer()
    } finally {
      release()
    }
  }

  async _acquireSpawnLock(lockFile) {
    await fsp.mkdir(path.dirname(lockFile), { recursive: true })
    const deadline = Date.now() + 120_000
    for (;;) {
      try {
        const fd = fs.openSync(lockFile, 'wx')
        fs.writeSync(fd, String(process.pid))
        fs.closeSync(fd)
        let released = false
        return () => {
          if (released) return
          released = true
          try {
            fs.unlinkSync(lockFile)
          } catch {}
        }
      } catch (err) {
        if (err.code !== 'EEXIST') throw err
      }
      // Another process is starting a server: wait for its state to appear.
      const st = this.freshState() || this.serverAlive()
      if (st) {
        try {
          fs.unlinkSync(lockFile)
        } catch {}
        return () => {}
      }
      try {
        const age = Date.now() - fs.statSync(lockFile).mtimeMs
        if (age > 180_000) fs.unlinkSync(lockFile)
      } catch {}
      if (Date.now() > deadline) {
        throw new BmaRpcError('BMA_SERVER_START_TIMEOUT', 'Timed out waiting for another process to start the MATLAB server.')
      }
      await sleep(300)
    }
  }

  async _spawnServer() {
    for (const dir of [this.inbox, this.outbox, this.done]) {
      await fsp.mkdir(dir, { recursive: true })
    }
    // MATLAB must be able to write its preferences and temp files. Under the
    // DSH file sandbox (%APPDATA% is read-only) startup aborts with
    // "failed to load settings errors_warnings plugin", so redirect every
    // writable location into the workspace before spawning. The control and
    // worker servers use separate pref/temp trees so they cannot corrupt each
    // other's settings.
    const tmpRoot = this.runtimeRoot
    const prefDir = path.join(tmpRoot, 'matlab_pref')
    const tempDir = path.join(tmpRoot, 'temp')
    const homeDir = path.join(tmpRoot, 'home')
    for (const dir of [prefDir, tempDir, homeDir]) {
      await fsp.mkdir(dir, { recursive: true })
    }
    // An empty prefdir can make MATLAB's settings service abort on the first
    // sandboxed start. Seed from an initialized template when one is available.
    const templates = [
      path.join(this.projectRoot, 'bridge', 'resources', 'matlab_pref_template'),
      path.join(this.projectRoot, '.tmp', 'matlab_pref_template'),
    ]
    const template = templates.find((p) => fs.existsSync(p))
    try {
      if (fs.readdirSync(prefDir).length === 0 && template) {
        fs.cpSync(template, prefDir, { recursive: true, force: true })
      }
    } catch {
      // Seeding is best-effort.
    }
    const spawnEnv = {
      ...this.env,
      MATLAB_PREFDIR: prefDir,
      TMP: tempDir,
      TEMP: tempDir,
      HOME: homeDir,
      USERPROFILE: this.env.USERPROFILE || process.env.USERPROFILE,
    }
    const matlabDir = path.join(this.projectRoot, 'matlab')
    const startOpts =
      this.serverSubdir === 'server'
        ? ''
        : `, struct('serverSubdir', ${matlabStr(this.serverSubdir)})`
    const cmd =
      `addpath(${matlabStr(matlabDir)}); ` +
      `bma.server.start(${matlabStr(this.workDir)}, ${matlabStr(this.token)}${startOpts})`
    const logFile = path.join(this.serverDir, 'matlab-stdout.log')
    const attempts = 3
    let lastError = null
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      const logFd = fs.openSync(logFile, 'a')
      this.child = spawn(this.matlabExe, ['-batch', cmd], {
        // Run from the session workspace so any relative write a MATLAB
        // function might make lands there, never in the agent installation
        // checkout.
        cwd: this.workDir,
        env: spawnEnv,
        windowsHide: true,
        stdio: ['ignore', logFd, logFd],
      })
      fs.closeSync(logFd)
      this.child.on('error', (err) => {
        this.lastLog = `spawn error: ${err.message}`
      })
      this.child.unref()
      try {
        const ready = await this.waitForReady()
        // A new server must not inherit a cancel flag from the previous
        // generation (especially the global flag mirrored for Sobol/fit).
        try {
          fs.unlinkSync(path.join(this.workDir, '.bma', 'server', 'cancel.flag'))
        } catch {}
        try {
          fs.unlinkSync(path.join(this.serverDir, 'cancel.flag'))
        } catch {}
        return ready
      } catch (err) {
        lastError = err
        const recoverable =
          err instanceof BmaRpcError &&
          ['BMA_SERVER_EXITED', 'BMA_SERVER_START_TIMEOUT'].includes(err.code)
        if (!recoverable || attempt === attempts) throw err
        // A first launch in a fresh prefdir can abort once; retry warm.
        await sleep(3000)
        this.child = null
      }
    }
    throw lastError
  }

  async waitForReady() {
    const deadline = Date.now() + this.startupTimeoutMs
    while (Date.now() < deadline) {
      const st = readJsonSafe(this.stateFile)
      if (st && st.pid && isAlive(st.pid)) {
        if (st.token !== this.token && this.freshState()) {
          // Another process won the startup race; adopt its server.
          this.token = st.token
          this._confirmed = true
          this._state = st
          return st
        }
        if (st.token === this.token) {
          const age = Date.now() - Date.parse(st.heartbeat || 0)
          if (Number.isFinite(age) && age < 10_000) {
            this._confirmed = true
            this._state = st
            return st
          }
        }
      }
      if (this.child && this.child.exitCode !== null) {
        const winner = this.freshState()
        if (winner) {
          this.token = winner.token
          this._confirmed = true
          this._state = winner
          return winner
        }
        const tail = readTail(path.join(this.serverDir, 'matlab-stdout.log'), 2000)
        throw new BmaRpcError(
          'BMA_SERVER_EXITED',
          `MATLAB server exited before becoming ready (code ${this.child.exitCode}).\n${tail}`
        )
      }
      await sleep(150)
    }
    const tail = readTail(path.join(this.serverDir, 'matlab-stdout.log'), 3000)
    throw new BmaRpcError(
      'BMA_SERVER_START_TIMEOUT',
      `MATLAB server did not become ready within ${this.startupTimeoutMs} ms. ${lastError}\n${tail}`
    )
  }

  /**
   * Call one RPC method. Calls are serialized inside one bridge instance.
   *
   * A BMA_TIMEOUT is treated as a hard failure: the server is restarted and
   * the error is returned immediately instead of being retried. Retrying a
   * heavy call after a timeout doubles the wait and was the root cause of the
   * 2026-11 Buchwald session lock-up (issue I1). Server-exit/auth/startup
   * failures remain retryable exactly once.
   *
   * @returns {Promise<{result:any, elapsedMs:number, rpcId:string}>}
   */
  call(method, params = {}, opts = {}) {
    const run = async () => {
      const generation = this._generation
      if (this._unhealthyUntil && Date.now() < this._unhealthyUntil && !opts.force) {
        throw new BmaRpcError(
          'BMA_SERVER_UNHEALTHY',
          `MATLAB server is marked unhealthy until ${new Date(this._unhealthyUntil).toISOString()} after a timeout. ` +
            'Call matlab_status or bma_cancel, then retry with a smaller workload.',
          { details: this.healthSync() }
        )
      }
      const timeoutMs = opts.timeoutMs ?? this.timeoutMs
      let lastErr = null
      for (let attempt = 0; attempt < 2; attempt += 1) {
        try {
          return await this._callOnce(method, params, timeoutMs, opts)
        } catch (err) {
          lastErr = err
          this._lastError = describeError(err, method)
          if (generation !== this._generation) {
            throw new BmaRpcError(
              'BMA_CANCELLED',
              `RPC ${method} was cancelled by a bma_cancel/restart request.`,
              { details: this.healthSync(), id: err && err.rpcId }
            )
          }
          // Never auto-retry a timed-out heavy call. Kill the stuck server so
          // queued calls do not inherit its single-threaded backlog. The
          // replacement starts lazily on the next call; waiting for a full
          // MATLAB boot inside the timeout path would just extend the outage.
          if (err instanceof BmaRpcError && err.code === 'BMA_TIMEOUT') {
            this._lastTimeout = {
              method,
              at: new Date().toISOString(),
              timeout_ms: timeoutMs,
              rpc_id: err.rpcId || null,
            }
            let killInfo = null
            let killError = null
            try {
              killInfo = await this.killServer('timeout')
            } catch (killErr) {
              killError = String(killErr && killErr.message ? killErr.message : killErr)
            }
            throw new BmaRpcError(
              'BMA_TIMEOUT',
              `${err.message}\nThe stuck MATLAB process was killed; the call was not retried. ` +
                'The next call starts a fresh process. Check matlab_status, then retry with a smaller workload or use bma_cancel.',
              {
                details: {
                  ...this.healthSync(),
                  killed: Boolean(killInfo && killInfo.killed),
                  restarted: false,
                  restarts_on_next_call: true,
                  retried: false,
                  kill_error: killError,
                },
                id: err.rpcId,
              }
            )
          }
          const recoverable =
            err instanceof BmaRpcError &&
            ['BMA_SERVER_EXITED', 'BMA_SERVER_START_TIMEOUT', 'BMA_AUTH'].includes(err.code)
          if (!recoverable || attempt > 0) throw err
          await this.restart('recoverable-error')
        }
      }
      throw lastErr
    }
    this._queueDepth += 1
    const next = this._queue.then(run, run).finally(() => {
      this._queueDepth = Math.max(0, this._queueDepth - 1)
    })
    this._queue = next.catch(() => {})
    return next
  }

  async _callOnce(method, params, timeoutMs, opts) {
    await this.ensureServer()
    const id = `r-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`
    const request = {
      schema: 'bma.rpc.v1',
      id,
      token: this.token,
      method,
      params,
      work_dir: opts.workDir || this.workDir,
      server_subdir: this.serverSubdir,
      timeout_s: Math.ceil(timeoutMs / 1000),
    }
    if (opts.runDir) request.run_dir = opts.runDir
    const reqFile = path.join(this.inbox, `${id}.json`)
    const resFile = path.join(this.outbox, `${id}.json`)
    this._inFlight = {
      id,
      method,
      startedAt: Date.now(),
      timeoutMs,
      request_file: reqFile,
    }
    try {
      atomicWriteJson(reqFile, request)
      const deadline = Date.now() + timeoutMs
      let missingState = 0
      while (Date.now() < deadline) {
        // A concurrent restart/cancel clears _inFlight; stop waiting for a
        // response that can no longer arrive on this server generation.
        if (!this._inFlight || this._inFlight.id !== id) {
          throw new BmaRpcError('BMA_CANCELLED', `RPC ${method} was cancelled during restart.`, { id })
        }
        const response = readJsonSafe(resFile)
        if (response && response.id === id) {
          try {
            fs.unlinkSync(resFile)
          } catch {}
          if (response.ok) {
            this._lastError = null
            return { result: response.result, elapsedMs: response.elapsed_ms, rpcId: id }
          }
          throw new BmaRpcError(response.error?.code || 'BMA_ERROR', response.error?.message || 'Unknown MATLAB error', {
            details: response.error?.details,
            elapsedMs: response.elapsed_ms,
            id,
          })
        }
        if (!this.serverAlive()) {
          missingState += 1
          if (missingState > 50) {
            throw new BmaRpcError('BMA_SERVER_EXITED', 'MATLAB server process died while handling the call.')
          }
        } else {
          missingState = 0
        }
        await sleep(60)
      }
      throw new BmaRpcError(
        'BMA_TIMEOUT',
        `RPC ${method} exceeded ${timeoutMs} ms (request ${id}). Increase timeout or reduce the workload.`,
        {
          id,
          details: {
            method,
            timeout_ms: timeoutMs,
            elapsed_ms: timeoutMs,
            server_busy: true,
            suggestion: 'Reduce multistart/time window or number of states; use bma_cancel to abort a stuck call.',
          },
        }
      )
    } finally {
      this._inFlight = null
    }
  }

  /** Cheap, non-blocking health snapshot (never queues behind a heavy call). */
  healthSync() {
    const st = this.state()
    return {
      work_dir: this.workDir,
      server_subdir: this.serverSubdir,
      server_alive: Boolean(this.serverAlive()),
      busy: Boolean(this._inFlight),
      current_call: this._inFlight ? this._inFlight.method : null,
      current_rpc_id: this._inFlight ? this._inFlight.id : null,
      busy_since: this._inFlight ? new Date(this._inFlight.startedAt).toISOString() : null,
      busy_ms: this._inFlight ? Date.now() - this._inFlight.startedAt : 0,
      queue_depth: this._queueDepth,
      last_timeout: this._lastTimeout,
      last_error: this._lastError,
      last_restart: this._lastRestart,
      restarts: this._restarts,
      workspace_writable: probeWorkspace(this.workDir),
      server_state: st
        ? {
            pid: st.pid,
            started_at: st.started_at || null,
            heartbeat: st.heartbeat || null,
            agent_version: st.agent_version || null,
            busy: Boolean(st.busy),
            current_call: st.current_call || null,
            last_method: st.last_method || null,
            queue_depth: st.queue_depth,
            last_timeout: st.last_timeout || null,
            last_error: st.last_error || null,
          }
        : null,
    }
  }

  /**
   * Health snapshot for matlab_status. Starts the server when missing (unless
   * disabled) and queries server.info only when the bridge is idle; during a
   * heavy call it returns the in-memory snapshot immediately instead of
   * queueing behind the stuck call (issue I1/U1.3).
   */
  async health({ startIfNeeded = true, ping = true } = {}) {
    let base = this.healthSync()
    if (!base.server_alive && startIfNeeded && this.allowAutoStart) {
      try {
        await this.ensureServer()
        base = this.healthSync()
      } catch (err) {
        this._lastError = describeError(err, 'server.info')
        base = this.healthSync()
        base.start_error = err instanceof BmaRpcError
          ? { code: err.code, message: err.message }
          : { code: 'BMA_SERVER_START_FAILED', message: String(err && err.message ? err.message : err) }
        return base
      }
    }
    if (!ping || base.busy || base.queue_depth > 0 || !base.server_alive) return base
    try {
      const { result } = await this._callOnce('server.info', {}, 20_000, {})
      return {
        ...base,
        ...result,
        // server.info itself is the in-flight call; keep the pre-ping snapshot
        // for busy/queue so the summary does not claim "BUSY server.info".
        busy: base.busy,
        busy_since: base.busy_since,
        busy_ms: base.busy_ms,
        current_call: base.current_call,
        current_rpc_id: base.current_rpc_id,
        queue_depth: base.queue_depth,
        status: base,
        ok: true,
        server_alive: true,
      }
    } catch (err) {
      this._lastError = describeError(err, 'server.info')
      return {
        ...base,
        status: base,
        ok: false,
        server_alive: this.serverAlive(),
        health_error: {
          code: err instanceof BmaRpcError ? err.code : 'BMA_HEALTH_FAILED',
          message: String(err && err.message ? err.message : err),
        },
      }
    }
  }

  async _writeCancelFlag(reason) {
    const dirs = [this.serverDir, path.join(this.workDir, '.bma', 'server')]
    for (const dir of dirs) {
      try {
        await fsp.mkdir(dir, { recursive: true })
        fs.writeFileSync(path.join(dir, 'cancel.flag'), reason)
      } catch {}
    }
  }

  /**
   * Kill the current server process tree and remove its state, WITHOUT waiting
   * for a replacement. The next call lazily starts a fresh server. This keeps
   * bma_cancel and timeout recovery bounded: a broken MATLAB start can never
   * make the cancel call hang for minutes.
   */
  async killServer(reason = 'manual') {
    this._restarts += 1
    this._lastRestart = { reason, at: new Date().toISOString() }
    await this._writeCancelFlag(reason)
    const st = this.state()
    const pids = new Set()
    if (st && st.pid) pids.add(Number(st.pid))
    if (this.child && this.child.pid) pids.add(Number(this.child.pid))
    for (const pid of pids) {
      if (!Number.isFinite(pid) || pid <= 0) continue
      // taskkill /T handles the MATLAB launcher + child process tree; fall
      // back to Node's kill when taskkill is unavailable.
      try {
        spawnSync('taskkill', ['/PID', String(pid), '/F', '/T'], { stdio: 'ignore', windowsHide: true })
      } catch {
        try {
          process.kill(pid)
        } catch {}
      }
      for (let i = 0; i < 30 && isAlive(pid); i += 1) await sleep(100)
    }
    if (this.child && this.child.exitCode === null) {
      try {
        this.child.kill()
      } catch {}
    }
    this.child = null
    this._confirmed = false
    this._inFlight = null
    await fsp.rm(this.stateFile, { force: true })
    this._unhealthyUntil = Date.now() + 1_000
    return { killed: true, pids: [...pids] }
  }

  /**
   * Restart the server (kill + start). Used by recoverable transient errors.
   * Timeout/cancel paths use killServer and let the next call start lazily.
   */
  async restart(reason = 'manual') {
    await this.killServer(reason)
    try {
      const next = await this.ensureServer()
      this._unhealthyUntil = 0
      // The global cancel flag is mirrored for Sobol/fit cooperative checks;
      // clear it after the target server has restarted so the next heavy call
      // does not abort on a stale flag.
      try {
        fs.unlinkSync(path.join(this.workDir, '.bma', 'server', 'cancel.flag'))
      } catch {}
      try {
        fs.unlinkSync(path.join(this.serverDir, 'cancel.flag'))
      } catch {}
      return next
    } catch (err) {
      this._unhealthyUntil = Date.now() + 30_000
      throw err
    }
  }

  /**
   * Cancel the current heavy call. A cooperative cancel.flag is written first
   * (Sobol/fit loops check it); if the call is still running after graceMs and
   * hard=true, the MATLAB process tree is killed. The replacement worker starts
   * lazily on the next heavy call, so cancel itself is bounded and cannot hang
   * on a slow MATLAB boot.
   */
  async cancel({ hard = true, graceMs = 3_000 } = {}) {
    const target = this._inFlight
    if (!target) {
      return { cancelled: false, reason: 'idle', hard: Boolean(hard), health: this.healthSync() }
    }
    await this._writeCancelFlag('cancel')
    if (!hard) {
      return {
        cancelled: true,
        requested: true,
        killed: false,
        restarted: false,
        running: true,
        method: target.method,
        rpc_id: target.id,
        health: this.healthSync(),
      }
    }
    const deadline = Date.now() + Math.max(0, Number(graceMs) || 0)
    while (this._inFlight && Date.now() < deadline) await sleep(100)
    if (!this._inFlight) {
      return {
        cancelled: false,
        reason: 'finished-before-cancel',
        method: target.method,
        rpc_id: target.id,
        health: this.healthSync(),
      }
    }
    this._generation += 1
    const killed = await this.killServer('cancel')
    return {
      cancelled: true,
      requested: true,
      killed: true,
      restarted: false,
      restarts_on_next_call: true,
      pids: killed.pids,
      method: target.method,
      rpc_id: target.id,
      health: this.healthSync(),
    }
  }

  async stop() {
    try {
      if (this.serverAlive()) {
        await this.call('server.stop', {}, { timeoutMs: 15_000 })
      }
    } catch {}
    const st = this.state()
    if (st && st.pid && isAlive(st.pid)) {
      for (let i = 0; i < 50 && isAlive(st.pid); i += 1) await sleep(100)
      if (isAlive(st.pid)) {
        try {
          process.kill(st.pid)
        } catch {}
      }
    }
  }
}

function normalizeServerSubdir(value) {
  const text = String(value || 'server').trim().replace(/\\/g, '/')
  if (!text || text.startsWith('/') || /^[A-Za-z]:/.test(text)) {
    throw new Error(`serverSubdir must be a relative path under .bma, got: ${value}`)
  }
  const parts = text.split('/').filter(Boolean)
  if (parts.some((p) => p === '..' || p === '.')) {
    throw new Error(`serverSubdir cannot contain . or .. segments: ${value}`)
  }
  return parts.join('/')
}

function describeError(err, method) {
  return {
    method,
    code: err && err.code ? err.code : 'BMA_ERROR',
    message: String(err && err.message ? err.message : err).slice(0, 800),
    at: new Date().toISOString(),
  }
}

function probeWorkspace(workDir) {
  try {
    const dir = path.join(workDir, '.bma')
    fs.mkdirSync(dir, { recursive: true })
    const file = path.join(dir, `.write-probe-${process.pid}-${Date.now()}`)
    fs.writeFileSync(file, 'ok')
    fs.unlinkSync(file)
    return true
  } catch {
    return false
  }
}

function readTail(file, bytes) {  try {
    const stat = fs.statSync(file)
    const start = Math.max(0, stat.size - bytes)
    const fd = fs.openSync(file, 'r')
    const buf = Buffer.alloc(stat.size - start)
    fs.readSync(fd, buf, 0, buf.length, start)
    fs.closeSync(fd)
    return buf.toString('utf8')
  } catch {
    return ''
  }
}

function defaultProjectRoot() {
  // bridge/lib -> project root (also correct when bridge/ is a junction target).
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
}
