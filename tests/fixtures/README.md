# Literature fixtures (QA)

Synthetic, **original** English research papers used to exercise the BioModel-MATLAB
literature-ingestion and end-to-end modelling pipeline. Everything in this directory
is fabricated for testing: the studies, authors, affiliations, journals and DOIs do
not exist, and the numbers were produced by the deterministic generators described
below. No third-party or copyrighted text is reproduced. The only real works cited
are classic foundational papers (Michaelis & Menten 1913, Briggs & Haldane 1925,
Goodwin 1965, Kermack & McKendrick 1927, etc.), cited by reference as normal
scholarship; all article text is original.

## Fixtures

| Fixture | Topic | Expected model | Formatted versions | Data |
|---|---|---|---|---|
| `enzyme_kinetics` | SDR enzyme, Michaelis–Menten steady state + progress curve | enzyme kinetics ODE (mass action, E/S/ES/P) | md, txt, html, docx, pdf | `data/substrate_velocity.csv`, `data/progress_curve_S50.csv` |
| `gene_oscillator` | Three-stage negative-feedback gene circuit, cell-free TX-TL limit cycle | Goodwin-type oscillator (3 species, Hill repression) | md, txt, html, docx, pdf | `data/oscillation_timeseries.csv` |
| `epidemic_sir` | Closed-island respiratory outbreak, 120 days | SIR compartmental ODE | md, txt, html, docx, pdf | `data/community_cases.csv` |

Each fixture directory contains:

- `paper.md` — source of truth, authored by hand (journal-style: Abstract,
  Introduction, Methods, Results, Discussion, References).
- `paper.txt` — plain-text rendering generated from `paper.md`.
- `paper.html` — single-file HTML rendering generated from `paper.md`.
- `paper.docx` — Word rendering generated with the bundled `python-docx`.
- `paper.pdf` — PDF rendering converted from `paper.docx` with the bundled
  LibreOffice Kit (text-based, not a scan; suitable for `extractFileText`).
- `expected_facts.json` — the *ground truth* the QA layer asserts against:
  expected model kind/archetype, expected species, parameter names/symbols,
  units, values, tolerances, evidence hints and the fixture data sets with
  `output_map` hints.
- `data/*.csv` — deterministic synthetic measurements consistent with the
  numbers printed in the paper.

## Regenerating

```powershell
# 1. deterministic CSV data (numpy only, fixed seeds)
& "<bundled-python>" tests/fixtures/tools/make_fixtures.py data

# 2. paper.md -> paper.txt / paper.html / paper.docx  (numpy + python-docx)
& "<bundled-python>" tests/fixtures/tools/make_fixtures.py convert

# 3. paper.docx -> paper.pdf  (bundled LibreOffice Kit, absolute node + cli paths)
powershell -NoProfile -ExecutionPolicy Bypass -File tests/fixtures/tools/convert_pdfs.ps1
```

`data` is reproducible byte-for-byte. `convert`/`convert_pdfs` are deterministic
apart from the document timestamps that Word/PDF writers embed. The PDFs are
text-based (embedded ToUnicode maps, no encryption) and are intended for
`extractFileText`; extraction quality is asserted by the MATLAB ingestion tests.

## How the fixtures are used

1. **MATLAB ingestion tests** (`matlab/tests/test_integration_literature.m`): every
   format (`.md`, `.txt`, `.html`, `.docx`, `.pdf`) is ingested through
   `bma.io.ingest`, and sections/numbers are asserted against `expected_facts.json`.
2. **Integration/fit tests** (`matlab/tests/test_integration_*.m`): the CSV data
   plus the hand-written spec in `spec/examples/` (same three model classes)
   exercise validate → build → analyze → simulate → fit → report → codegen.
3. **Headless E2E** (`tests/e2e/run_headless_e2e.ps1`): a real DeepSeek model is
   given one fixture directory and asked to build, fit and report the model.
   `tests/e2e/assert_e2e.ps1` checks the artifacts and cross-checks
   `expected_facts.json`.

## Notes on fidelity

- Values in the CSV files are the same as those printed in the papers; small
  seeded noise (1–3% relative) was added where the Methods sections say the
  measurements were repeated.
- `enzyme_kinetics` provides both a steady-state (substrate vs initial velocity)
  table and a time-course progress curve, because an ODE model cannot be fitted
  to a saturation curve directly. The progress curve is the recommended fit target.
- `gene_oscillator` starts within 2% of the unstable steady state; the first
  ~400 min therefore show amplitude growth before the limit cycle stabilizes.
- `epidemic_sir` counts are integers; `cumulative_infections = active + removed`
  by construction.
