#!/usr/bin/env node
/**
 * Detach a long-running process from the calling shell/tool-call process tree.
 *
 *   node scripts/detach.mjs <executable> [args...]
 *
 * Prints the detached pid. Uses a new process group (detached: true) so a
 * tool-call cleanup that reaps the caller's children does not kill the server.
 * On Windows a detached process still inherits the caller's job object; whether
 * it can break away depends on the job's breakaway policy, so callers should
 * verify survival and fall back to running the process from a persistent host.
 */
import { spawn } from 'node:child_process'

const [cmd, ...args] = process.argv.slice(2)
if (!cmd) {
  console.error('usage: node scripts/detach.mjs <executable> [args...]')
  process.exit(2)
}
const child = spawn(cmd, args, {
  detached: true,
  stdio: 'ignore',
  windowsHide: true,
  cwd: process.cwd(),
})
child.unref()
console.log(child.pid)
