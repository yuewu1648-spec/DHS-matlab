"""Generate and convert BioModel-MATLAB literature fixtures.

The *content* of the three papers is authored by hand in ``paper.md`` files
(original English text, fictional studies).  This script does the mechanical
work so the fixtures stay reproducible:

    python make_fixtures.py data     # regenerate the deterministic CSV fixtures
    python make_fixtures.py convert  # paper.md -> paper.txt / paper.docx / paper.html
    python make_fixtures.py all      # both steps

All randomness uses fixed seeds so every checkout gets byte-identical data.
The script depends on numpy + python-docx only (both bundled with the DSH
runtime Python).  PDF files are produced separately from the generated .docx
through the bundled LibreOffice Kit (see tests/fixtures/README.md).

Usage (bundled Python):
    C:\\Users\\LEGION\\.dsh\\dsh-runtimes\\dsh-primary-runtime\\dependencies\\python\\python.exe \
        tests/fixtures/tools/make_fixtures.py all
"""

from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]           # tests/fixtures
LIT = ROOT / "literature"


# --------------------------------------------------------------------------- #
# numerical helpers
# --------------------------------------------------------------------------- #
def rk4(rhs, y0, t_end: float, dt: float):
    """Integrate dy/dt = rhs(y) with fixed-step RK4; return (t, Y) arrays."""
    n = int(round(t_end / dt)) + 1
    y = np.asarray(y0, dtype=float).copy()
    ts = np.empty(n)
    ys = np.empty((n, y.size))
    ts[0], ys[0] = 0.0, y
    t = 0.0
    for k in range(1, n):
        k1 = rhs(y)
        k2 = rhs(y + 0.5 * dt * k1)
        k3 = rhs(y + 0.5 * dt * k2)
        k4 = rhs(y + dt * k3)
        y = y + (dt / 6.0) * (k1 + 2.0 * k2 + 2.0 * k3 + k4)
        t += dt
        ts[k], ys[k] = t, y
    return ts, ys


def sample_grid(t_fine, y_fine, t_grid):
    """Linear interpolation of a fine solution onto the reported sampling grid."""
    out = np.empty((len(t_grid), y_fine.shape[1]))
    for j in range(y_fine.shape[1]):
        out[:, j] = np.interp(t_grid, t_fine, y_fine[:, j])
    return out


def write_csv(path: Path, header, columns) -> None:
    data = np.column_stack(columns)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(",".join(header) + "\n")
        for row in data:
            fh.write(",".join(fmt_cell(v) for v in row) + "\n")


def fmt_cell(v) -> str:
    f = float(v)
    if f == int(f):
        return str(int(f))
    return f"{f:.6g}"


# --------------------------------------------------------------------------- #
# fixture 1: enzyme kinetics
# --------------------------------------------------------------------------- #
ENZYME = dict(
    km=12.5,          # uM
    kcat=4.8,         # 1/s
    etot=0.05,        # uM
    kf=1.0,           # 1/(uM*s)
    s0_progress=50.0,  # uM
)
ENZYME["kr"] = ENZYME["km"] * ENZYME["kf"] - ENZYME["kcat"]
ENZYME["vmax"] = ENZYME["kcat"] * ENZYME["etot"]


def gen_enzyme(out: Path) -> dict:
    p = ENZYME
    # (a) steady-state substrate vs initial velocity, 11 concentrations
    s_tab = np.array([0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 40.0, 60.0, 100.0, 150.0, 250.0])
    v_tab = p["vmax"] * s_tab / (p["km"] + s_tab)
    rng = np.random.default_rng(20261112)
    v_noisy = v_tab * (1.0 + 0.02 * rng.standard_normal(s_tab.size))
    write_csv(out / "data" / "substrate_velocity.csv",
              ["substrate_uM", "v0_uM_per_s"], [s_tab, v_noisy])

    # (b) full progress curve at [S]0 = 50 uM (P and S measured every 10 s)
    kf, kr, kcat = p["kf"], p["kr"], p["kcat"]

    def rhs(y):
        E, S, ES, P = y
        v1 = kf * E * S
        v2 = kr * ES
        v3 = kcat * ES
        return np.array([-v1 + v2 + v3, -v1 + v2, v1 - v2 - v3, v3])

    t_fine, y_fine = rk4(rhs, [p["etot"], p["s0_progress"], 0.0, 0.0], 600.0, 0.01)
    t_grid = np.arange(0.0, 601.0, 10.0)
    y = sample_grid(t_fine, y_fine, t_grid)
    rng = np.random.default_rng(20261113)
    P = y[:, 3] * (1.0 + 0.01 * rng.standard_normal(t_grid.size))
    S = y[:, 1] * (1.0 + 0.01 * rng.standard_normal(t_grid.size))
    write_csv(out / "data" / "progress_curve_S50.csv", ["time_s", "P_uM", "S_uM"],
              [t_grid, P, S])

    # summary numbers quoted in the paper
    t_grid_i = np.arange(0.0, 601.0, 1.0)
    yi = sample_grid(t_fine, y_fine, t_grid_i)
    t_half = float(t_grid_i[np.argmax(yi[:, 3] >= p["s0_progress"] / 2.0)])
    return dict(t_half_to_product=t_half, vmax=p["vmax"], kr=p["kr"],
                kcat_over_km=p["kcat"] / p["km"])


# --------------------------------------------------------------------------- #
# fixture 2: gene negative-feedback oscillator
# --------------------------------------------------------------------------- #
OSC = dict(
    alpha=32.0,     # nM/min maximal transcription
    K=25.0,         # nM repression half-effect
    h=10.0,         # Hill coefficient
    gamma_m=0.10,   # 1/min mRNA decay  (half-life ln2/0.1 = 6.93 min)
    beta=0.72,      # 1/min translation
    gamma_p=0.10,   # 1/min intermediate decay
    delta=0.72,     # 1/min repressor formation
    gamma_r=0.10,   # 1/min repressor decay
)


def osc_rhs(y):
    m, prog, rep = y
    a, K, h = OSC["alpha"], OSC["K"], OSC["h"]
    return np.array([
        a * K ** h / (K ** h + rep ** h) - OSC["gamma_m"] * m,
        OSC["beta"] * m - OSC["gamma_p"] * prog,
        OSC["delta"] * prog - OSC["gamma_r"] * rep,
    ])


def osc_steady_state() -> np.ndarray:
    """Unstable fixed point of the Goodwin loop (m, p, r), via robust bisection."""
    a, K, h = OSC["alpha"], OSC["K"], OSC["h"]
    gm, gp, gr = OSC["gamma_m"], OSC["gamma_p"], OSC["gamma_r"]
    # p = beta*m/gp, r = delta*p/gr, m = a*K^h/(K^h+r^h)/gm
    C = OSC["delta"] * OSC["beta"] * a / (gr * gp * gm)
    Kh = K ** h

    def f(r):
        return r - C * Kh / (Kh + r ** h)

    lo, hi = 0.0, C
    for _ in range(400):
        mid = 0.5 * (lo + hi)
        if f(mid) < 0:
            lo = mid
        else:
            hi = mid
    r = 0.5 * (lo + hi)
    m = a * Kh / (Kh + r ** h) / gm
    p = OSC["beta"] * m / gp
    return np.array([m, p, r])


def gen_oscillator(out: Path) -> dict:
    ss = osc_steady_state()
    y0 = ss * 1.02  # 2 % perturbation kicks the limit cycle
    t_fine, y_fine = rk4(osc_rhs, y0, 1560.0, 0.01)
    t_grid = np.arange(0.0, 1500.0 + 1e-9, 2.0)
    y = sample_grid(t_fine, y_fine, t_grid)
    rng = np.random.default_rng(20261114)
    m = y[:, 0] * (1.0 + 0.03 * rng.standard_normal(t_grid.size))
    prog = y[:, 1] * (1.0 + 0.03 * rng.standard_normal(t_grid.size))
    rep = y[:, 2] * (1.0 + 0.03 * rng.standard_normal(t_grid.size))
    write_csv(out / "data" / "oscillation_timeseries.csv",
              ["time_min", "mRNA_nM", "intermediate_nM", "repressor_nM"],
              [t_grid, m, prog, rep])

    # period / amplitude of the repressor on the second half of the trace
    late = t_grid >= 300.0
    tail = y[late, 2]
    tt = t_grid[late]
    mean = tail.mean()
    amp = (tail.max() - tail.min()) / 2.0
    peaks = [tt[i] for i in range(1, len(tail) - 1)
             if tail[i] > tail[i - 1] and tail[i] >= tail[i + 1]]
    troughs = [tt[i] for i in range(1, len(tail) - 1)
               if tail[i] < tail[i - 1] and tail[i] <= tail[i + 1]]
    period = float(np.mean(np.diff(peaks))) if len(peaks) > 1 else float("nan")
    return dict(steady_state=ss.tolist(), period=period, amp=amp,
                rep_min=float(tail.min()), rep_max=float(tail.max()),
                rep_mean=float(mean), n_peaks=len(peaks),
                m_mean=float(y[late, 0].mean()),
                m_amp=float((y[late, 0].max() - y[late, 0].min()) / 2.0),
                p_mean=float(y[late, 1].mean()))


# --------------------------------------------------------------------------- #
# fixture 3: SIR epidemic
# --------------------------------------------------------------------------- #
SIR = dict(N=1200.0, beta=0.45, gamma=0.16, s0=1188.0, i0=12.0)
SIR["r0"] = SIR["beta"] / SIR["gamma"]


def gen_sir(out: Path) -> dict:
    beta, gamma, N = SIR["beta"], SIR["gamma"], SIR["N"]

    def rhs(y):
        S, I, R = y
        inf = beta * S * I / N
        rec = gamma * I
        return np.array([-inf, inf - rec, rec])

    t_fine, y_fine = rk4(rhs, [SIR["s0"], SIR["i0"], 0.0], 120.0, 0.002)
    t_grid = np.arange(0.0, 121.0, 1.0)               # one row per epidemiological day
    y = sample_grid(t_fine, y_fine, t_grid)
    S, I, R = y[:, 0], y[:, 1], y[:, 2]
    rng = np.random.default_rng(20261115)
    active = np.maximum(0.0, np.rint(I + 0.5 * rng.standard_normal(t_grid.size)))
    cum = np.rint(N - S)                               # cumulative ever-infected
    cum = np.maximum.accumulate(cum)                   # counting data never decreases
    active = np.minimum(active, cum)
    removed = cum - active
    new_cases = np.concatenate([[SIR["i0"]], np.diff(cum)])
    new_cases = np.maximum(new_cases, 0.0)
    write_csv(out / "data" / "community_cases.csv",
              ["day", "new_cases", "active_infections",
               "cumulative_infections", "cumulative_removed"],
              [t_grid, new_cases, active, cum, removed])
    peak_i = float(np.max(t_grid[I == I.max()]))
    return dict(peak_day=peak_i, peak_active=float(I.max()),
                final_cum=float(cum[-1]), final_attack=float(cum[-1]) / N)


# --------------------------------------------------------------------------- #
# markdown -> txt / html / docx conversion
# --------------------------------------------------------------------------- #
def md_blocks(text: str):
    """Split markdown into blocks: ('h', level, text) / ('p', text) / ('table', rows)."""
    lines = text.splitlines()
    blocks = []
    i = 0
    while i < len(lines):
        line = lines[i]
        s = line.rstrip()
        if not s.strip():
            i += 1
            continue
        m = re.match(r"^(#{1,6})\s+(.*)$", s)
        if m:
            blocks.append(("h", len(m.group(1)), m.group(2).strip()))
            i += 1
            continue
        if s.lstrip().startswith("|"):
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith("|"):
                raw = lines[i].strip().strip("|")
                cells = [c.strip() for c in raw.split("|")]
                if not all(re.fullmatch(r":?-{2,}:?", c) for c in cells):
                    rows.append(cells)
                i += 1
            blocks.append(("table", rows))
            continue
        if re.match(r"^\s*[-*+]\s+", s):
            items = []
            while i < len(lines) and re.match(r"^\s*[-*+]\s+", lines[i]):
                items.append(re.sub(r"^\s*[-*+]\s+", "", lines[i]).strip())
                i += 1
            blocks.append(("ul", items))
            continue
        para = [s.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not re.match(
                r"^(#{1,6}\s|\s*[-*+]\s+|\|)", lines[i]):
            para.append(lines[i].strip())
            i += 1
        blocks.append(("p", " ".join(para)))
    return blocks


INLINE_RE = re.compile(r"(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`)")


def md_inline_txt(s: str) -> str:
    s = re.sub(r"\*\*([^*]+)\*\*", r"\1", s)
    s = re.sub(r"\*([^*]+)\*", r"\1", s)
    s = re.sub(r"`([^`]+)`", r"\1", s)
    return s


def md_inline_html(s: str) -> str:
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    s = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"\*([^*]+)\*", r"<em>\1</em>", s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    return s


def to_txt(md: str) -> str:
    out = []
    for b in md_blocks(md):
        if b[0] == "h":
            out.append(md_inline_txt(b[2]))
        elif b[0] == "p":
            out.append(md_inline_txt(b[1]))
        elif b[0] == "ul":
            out.extend("  - " + md_inline_txt(x) for x in b[1])
        elif b[0] == "table":
            rows = b[1]
            for r in rows:
                out.append("  ".join(md_inline_txt(c) for c in r))
            out.append("")
    return "\n\n".join(out) + "\n"


def to_html(md: str, title: str) -> str:
    body = []
    for b in md_blocks(md):
        if b[0] == "h":
            lvl = min(b[1] + 0, 6)
            body.append(f"<h{lvl}>{md_inline_html(b[2])}</h{lvl}>")
        elif b[0] == "p":
            body.append(f"<p>{md_inline_html(b[1])}</p>")
        elif b[0] == "ul":
            body.append("<ul>" + "".join(f"<li>{md_inline_html(x)}</li>" for x in b[1]) + "</ul>")
        elif b[0] == "table":
            rows = b[1]
            if not rows:
                continue
            head = "".join(f"<th>{md_inline_html(c)}</th>" for c in rows[0])
            rest = "".join(
                "<tr>" + "".join(f"<td>{md_inline_html(c)}</td>" for c in r) + "</tr>"
                for r in rows[1:])
            body.append(f"<table><caption></caption><thead><tr>{head}</tr></thead>"
                        f"<tbody>{rest}</tbody></table>")
    return (
        "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        f"<title>{md_inline_html(title)}</title>\n"
        "<style>body{font-family:Georgia,serif;max-width:760px;margin:2em auto;"
        "line-height:1.5;}table{border-collapse:collapse;margin:1em 0;}"
        "td,th{border:1px solid #888;padding:4px 8px;}</style>\n</head>\n<body>\n"
        + "\n".join(body) + "\n</body>\n</html>\n"
    )


def to_docx(md: str, out_path: Path, title: str) -> None:
    from docx import Document
    from docx.shared import Pt

    doc = Document()
    style = doc.styles["Normal"]
    style.font.name = "Times New Roman"
    style.font.size = Pt(11)
    if title:
        t = doc.add_paragraph()
        run = t.add_run(title)
        run.bold = True
        run.font.size = Pt(15)
    for b in md_blocks(md):
        if b[0] == "h":
            if b[1] == 1 and md_inline_txt(b[2]).strip() == title.strip():
                continue
            lvl = min(b[1], 4)
            doc.add_heading(md_inline_txt(b[2]), level=lvl)
        elif b[0] == "p":
            doc.add_paragraph(md_inline_txt(b[1]))
        elif b[0] == "ul":
            for x in b[1]:
                doc.add_paragraph(md_inline_txt(x), style="List Bullet")
        elif b[0] == "table":
            rows = b[1]
            if not rows:
                continue
            ncol = max(len(r) for r in rows)
            table = doc.add_table(rows=0, cols=ncol)
            table.style = "Table Grid"
            for ri, r in enumerate(rows):
                cells = table.add_row().cells
                for ci in range(ncol):
                    txt = md_inline_txt(r[ci]) if ci < len(r) else ""
                    cells[ci].text = txt
                    if ri == 0:
                        for para in cells[ci].paragraphs:
                            for run in para.runs:
                                run.bold = True
    out_path.parent.mkdir(parents=True, exist_ok=True)
    doc.save(str(out_path))


def convert_all() -> None:
    for paper in sorted(LIT.glob("*/paper.md")):
        fixture = paper.parent
        md = paper.read_text(encoding="utf-8")
        title = paper_title(md)
        (fixture / "paper.txt").write_text(to_txt(md), encoding="utf-8")
        (fixture / "paper.html").write_text(to_html(md, title), encoding="utf-8")
        to_docx(md, fixture / "paper.docx", title)
        print(f"converted {fixture.name}: paper.txt / paper.html / paper.docx")


def paper_title(md: str) -> str:
    for line in md.splitlines():
        m = re.match(r"^#\s+(.*)$", line.strip())
        if m:
            return m.group(1).strip()
    return ""


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def gen_data() -> None:
    for name, fn in (("enzyme_kinetics", gen_enzyme),
                     ("gene_oscillator", gen_oscillator),
                     ("epidemic_sir", gen_sir)):
        out = LIT / name
        out.mkdir(parents=True, exist_ok=True)
        stats = fn(out)
        print(f"[{name}] {json.dumps(stats, indent=None, default=float)}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("step", choices=["data", "convert", "all"])
    args = ap.parse_args()
    if args.step in ("data", "all"):
        gen_data()
    if args.step in ("convert", "all"):
        convert_all()


if __name__ == "__main__":
    main()
