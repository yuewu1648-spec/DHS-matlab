#!/usr/bin/env node
/**
 * Tool-parameter regression for 0.5.0: a report extra_sections file path must
 * pass through as a path, not be mistaken for malformed JSON (issue I5).
 */
import assert from 'node:assert/strict'
import { TOOL_SPECS } from '../lib/tools.js'

const byName = new Map(TOOL_SPECS.map((s) => [s.name, s]))

const report = byName.get('bma_report_build')
assert.ok(report, 'bma_report_build missing')
const pathArg = 'C:\\tmp\\report_sections.json'
const p1 = report.buildParams({ spec_path: 'spec.json', title: 't', extra_sections_json: pathArg })
assert.equal(typeof p1.extra_sections, 'string', 'file path must stay a string')
assert.equal(p1.extra_sections, pathArg)

const p2 = report.buildParams({
  spec_path: 'spec.json',
  title: 't',
  extra_sections_json: '[{"title":"A","markdown":"body"}]',
})
assert.ok(Array.isArray(p2.extra_sections), 'JSON array must be parsed')

const gate = byName.get('bma_gate_waive')
assert.ok(gate, 'bma_gate_waive missing')
const p3 = gate.buildParams({ gate: 'G6', reason: 'numeric fallback', evidence: 'analysis.json' })
assert.equal(p3.evidence, 'analysis.json', 'plain evidence string must not be JSON-parsed')

const p4 = gate.buildParams({ gate: 'G6', reason: 'r', evidence: '{"path":"analysis.json"}' })
assert.equal(p4.evidence.path, 'analysis.json', 'JSON evidence object must be parsed')

console.log('TOOL PARAMS OK')
