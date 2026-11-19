/**
 * Agent version and compatibility facts.
 *
 * The version is the single source of truth in `<projectRoot>/VERSION`; the
 * bundle version lives in `bridge/package.json`. Tools and reports surface both
 * so a research project can pin the engine version it was modeled with.
 */
import fs from 'node:fs'
import path from 'node:path'

export const SPEC_SCHEMA = 'bma.modelSpec.v1'

function readTextSafe(file) {
  try {
    return fs.readFileSync(file, 'utf8').trim()
  } catch {
    return ''
  }
}

/**
 * @param {string} projectRoot absolute checkout path
 * @returns {{agentVersion:string, bundleVersion:string, specSchema:string, projectRoot:string}}
 */
export function readAgentVersion(projectRoot) {
  const agentVersion = readTextSafe(path.join(projectRoot, 'VERSION')) || '0.0.0-dev'
  let bundleVersion = '0.0.0-dev'
  try {
    const pkg = JSON.parse(fs.readFileSync(path.join(projectRoot, 'bridge', 'package.json'), 'utf8'))
    bundleVersion = pkg.version || bundleVersion
  } catch {
    // Keep the dev fallback.
  }
  return { agentVersion, bundleVersion, specSchema: SPEC_SCHEMA, projectRoot }
}
