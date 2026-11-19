#!/usr/bin/env node
/**
 * Command-line JSON-RPC client for the MATLAB bridge (developer tool).
 *
 * Examples:
 *   node bridge/lib/rpc-cli.mjs --method server.ping
 *   node bridge/lib/rpc-cli.mjs --method test.run --params '{"filter":"test_spec_"}'
 *   node bridge/lib/rpc-cli.mjs --method dev.eval --code-file tmp/probe.m
 *   node bridge/lib/rpc-cli.mjs --start
 *   node bridge/lib/rpc-cli.mjs --stop
 */
import fs from 'node:fs'
import path from 'node:path'
import { MatlabBridge } from './bridge-client.js'

function parseArgs(argv) {
  const out = {
    method: '',
    params: null,
    paramsFile: '',
    codeFile: '',
    workDir: process.cwd(),
    projectRoot: '',
    timeout: 0,
    start: false,
    stop: false,
    status: false,
    pretty: true,
    quiet: false,
  }
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i]
    const next = () => argv[++i]
    switch (a) {
      case '--method':
      case '-m':
        out.method = next()
        break
      case '--params':
      case '-p':
        out.params = next()
        break
      case '--params-file':
        out.paramsFile = next()
        break
      case '--code-file':
        out.codeFile = next()
        break
      case '--work-dir':
        out.workDir = next()
        break
      case '--project-root':
        out.projectRoot = next()
        break
      case '--timeout':
        out.timeout = Number(next()) * 1000
        break
      case '--start':
        out.start = true
        break
      case '--stop':
        out.stop = true
        break
      case '--status':
        out.status = true
        break
      case '--compact':
        out.pretty = false
        break
      case '--quiet':
        out.quiet = true
        break
      case '--help':
      case '-h':
        console.log(fs.readFileSync(new URL(import.meta.url), 'utf8').split('*/')[0])
        process.exit(0)
        break
      default:
        throw new Error(`Unknown argument: ${a}`)
    }
  }
  return out
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const workDir = path.resolve(args.workDir)
  const bridge = new MatlabBridge({
    workDir,
    projectRoot: args.projectRoot ? path.resolve(args.projectRoot) : undefined,
    // A shared keeper owns the server lifecycle. Plain calls only attach;
    // `--start` is the explicit operator action that may spawn MATLAB.
    allowAutoStart: args.start,
  })

  if (args.start) {
    const st = await bridge.ensureServer()
    console.log(JSON.stringify({ ok: true, server: st }, null, 2))
    return
  }
  if (args.stop) {
    await bridge.stop()
    console.log(JSON.stringify({ ok: true, stopped: true }))
    return
  }
  if (args.status) {
    const st = bridge.state()
    console.log(JSON.stringify({ ok: Boolean(st), server: st }, null, 2))
    return
  }
  if (!args.method) throw new Error('--method is required (or use --start/--stop/--status)')

  let params = {}
  if (args.paramsFile) {
    params = JSON.parse(fs.readFileSync(path.resolve(args.paramsFile), 'utf8'))
  } else if (args.params) {
    params = JSON.parse(args.params)
  }
  if (args.codeFile) {
    params.code = fs.readFileSync(path.resolve(args.codeFile), 'utf8')
  }
  const callOpts = {}
  if (args.timeout > 0) callOpts.timeoutMs = args.timeout // seconds -> ms
  const started = Date.now()
  const { result, elapsedMs } = await bridge.call(args.method, params, callOpts)
  const payload = {
    ok: true,
    method: args.method,
    elapsed_ms: elapsedMs,
    wall_ms: Date.now() - started,
    result,
  }
  if (!args.quiet) {
    console.log(JSON.stringify(payload, null, args.pretty ? 2 : 0))
  }
}

main().catch((err) => {
  const payload = {
    ok: false,
    code: err.code || 'CLI_ERROR',
    message: err.message,
    details: err.details,
  }
  console.error(JSON.stringify(payload, null, 2))
  process.exitCode = 1
})
