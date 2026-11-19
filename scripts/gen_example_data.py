"""Generate deterministic synthetic datasets for the three example model specs.

Run with the bundled Python:
    <python> scripts/gen_example_data.py

Outputs (committed as fixtures):
    spec/examples/data/enzyme_progress.csv
    spec/examples/data/goodwin_timeseries.csv
    spec/examples/data/sir_observations.csv
    spec/examples/data/truth.json

The generator is intentionally dependency-light (numpy only) and uses a fixed
RK4 grid plus seeded noise so every checkout gets byte-identical fixtures.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "spec" / "examples" / "data"
OUT.mkdir(parents=True, exist_ok=True)


def rk4(rhs, y0, t_eval, dt):
    """Integrate rhs(y) from y0, recording states on the t_eval grid (linear time)."""
    t_end = float(t_eval[-1])
    n_steps = int(np.ceil(t_end / dt)) + 1
    y = np.asarray(y0, dtype=float).copy()
    ys = np.empty((n_steps, y.size))
    ts = np.empty(n_steps)
    ys[0] = y
    ts[0] = 0.0
    t = 0.0
    for k in range(1, n_steps):
        h = min(dt, t_end - t) if t < t_end else 0.0
        k1 = rhs(y)
        k2 = rhs(y + 0.5 * h * k1)
        k3 = rhs(y + 0.5 * h * k2)
        k4 = rhs(y + h * k3)
        y = y + (h / 6.0) * (k1 + 2.0 * k2 + 2.0 * k3 + k4)
        t = t + h
        ys[k] = y
        ts[k] = t
    out = np.empty((len(t_eval), y.size))
    for j in range(y.size):
        out[:, j] = np.interp(t_eval, ts, ys[:, j])
    return out


def write_csv(path: Path, header: list[str], columns: list[np.ndarray]) -> None:
    data = np.column_stack(columns)
    with path.open("w", encoding="utf-8", newline="\n") as fh:
        fh.write(",".join(header) + "\n")
        for row in data:
            fh.write(",".join(f"{v:.6g}" for v in row) + "\n")


def enzyme() -> None:
    kf, kr, kcat = 0.5, 0.1, 2.0
    E0, S0 = 1.0, 10.0

    def rhs(y):
        E, S, ES, P = y
        v1 = kf * E * S
        v2 = kr * ES
        v3 = kcat * ES
        return np.array([-v1 + v2 + v3, -v1 + v2, v1 - v2 - v3, v3])

    t = np.arange(0, 61, 5.0)
    y = rk4(rhs, [E0, S0, 0.0, 0.0], t, 0.002)
    rng = np.random.default_rng(7)
    P = y[:, 3] * (1.0 + rng.normal(0, 0.01, t.size))
    S = y[:, 1] * (1.0 + rng.normal(0, 0.01, t.size))
    write_csv(OUT / "enzyme_progress.csv", ["time", "P_obs", "S_obs"], [t, P, S])
    truth = {"enzyme_mm": {"kf": kf, "kr": kr, "kcat": kcat,
                           "E0": E0, "S0": S0}}
    return truth


def goodwin() -> None:
    alpha, K, h = 10.0, 1.0, 12.0
    gm, beta, gp, delta, gr = 0.3, 2.0, 0.3, 2.0, 0.3

    def rhs(y):
        m, p, r = y
        return np.array([
            alpha * K**h / (K**h + r**h) - gm * m,
            beta * m - gp * p,
            delta * p - gr * r,
        ])

    t = np.arange(0, 601, 3.0)
    y = rk4(rhs, [0.2, 0.2, 0.2], t, 0.01)
    rng = np.random.default_rng(11)
    m = y[:, 0] * (1.0 + rng.normal(0, 0.02, t.size))
    p = y[:, 1] * (1.0 + rng.normal(0, 0.02, t.size))
    write_csv(OUT / "goodwin_timeseries.csv", ["time", "m_obs", "p_obs"], [t, m, p])
    return {"goodwin": {"alpha": alpha, "K": K, "h": h, "gamma_m": gm,
                        "beta": beta, "gamma_p": gp, "delta": delta,
                        "gamma_r": gr}}


def sir() -> None:
    beta, gamma, N = 0.4, 0.14, 1000.0

    def rhs(y):
        S, I, R = y
        inf = beta * S * I / N
        rec = gamma * I
        return np.array([-inf, inf - rec, rec])

    t = np.arange(0, 161, 1.0)
    y = rk4(rhs, [990.0, 10.0, 0.0], t, 0.01)
    rng = np.random.default_rng(3)
    I = np.maximum(0.0, y[:, 1] + rng.normal(0, 0.03 * np.maximum(y[:, 1], 1.0)))
    R = np.maximum(0.0, y[:, 2] + rng.normal(0, 0.02 * np.maximum(y[:, 2], 1.0)))
    write_csv(OUT / "sir_observations.csv", ["time", "I_obs", "R_obs"], [t, I, R])
    return {"sir": {"beta": beta, "gamma": gamma, "N": N}}


def main() -> None:
    truth = {}
    truth.update(enzyme())
    truth.update(goodwin())
    truth.update(sir())
    (OUT / "truth.json").write_text(
        json.dumps(truth, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print("wrote fixtures to", OUT)


if __name__ == "__main__":
    main()
