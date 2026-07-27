#!/usr/bin/env python3.14
"""W26b M1-R0: retained W26 artifact re-analysis (plan v5 §1-M1).

Read-only over `.omc/verify/wave26/{results,logs}`. Self-check contract
(§5): this script must reproduce the three published W26 numbers exactly —
G2 dense/sync OFF-cost 1.0077/1.0047, G3 dense 0.9982, confirm flood
1.1806 — before any of its new derivations (component split, per-rep
join, estimator table, regime split) are trusted. A mismatch is an
M1 STOP. Emits `wave26b/results/w26b-retained.jsonl` and prints the
summary; the companion `M1-RETAINED-REANALYSIS.md` is written by the
wave from this output.

The confirm re-derivation mirrors `w26_energy.py` analyze semantics
verbatim: edge-trim [t0+2s, t1-2s], per-rep trimmed mean of
`combined_mw`, valid iff >= 50 trimmed samples, median of the 6 binding
rep means per arm.
"""

from __future__ import annotations

import json
import re
import statistics
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
W26 = REPO / ".omc" / "verify" / "wave26"
OUT = REPO / ".omc" / "verify" / "wave26b" / "results" / "w26b-retained.jsonl"

EDGE_TRIM_S = 2.0
MIN_TRIMMED = 50

SAMPLE_RE = re.compile(r"\*\*\* Sampled system activity \((.+?)\) \(([\d.]+)ms elapsed\)")
POWER_RES = {
    "cpu_mw": re.compile(r"^CPU Power:\s+([\d.]+)\s*mW", re.M),
    "gpu_mw": re.compile(r"^GPU Power:\s+([\d.]+)\s*mW", re.M),
    "ane_mw": re.compile(r"^ANE Power:\s+([\d.]+)\s*mW", re.M),
    "combined_mw": re.compile(r"^Combined Power \(CPU \+ GPU \+ ANE\):\s+([\d.]+)\s*mW", re.M),
}
FT_KV = re.compile(r"(\w+)=([-\d.]+)")


def parse_powermetrics(path: Path) -> list[dict]:
    text = path.read_text(errors="replace")
    records = []
    blocks = SAMPLE_RE.split(text)
    for i in range(1, len(blocks) - 2, 3):
        ts_raw, body = blocks[i], blocks[i + 2]
        ts_clean = re.sub(r"\s+[+-]\d{4}$", "", ts_raw.strip())
        try:
            epoch = time.mktime(time.strptime(ts_clean, "%a %b %d %H:%M:%S %Y"))
        except ValueError:
            continue
        rec = {"epoch": epoch}
        for key, rx in POWER_RES.items():
            m = rx.search(body)
            if m:
                rec[key] = float(m.group(1))
        records.append(rec)
    return records


def component_split(name: str, path: Path) -> dict:
    samples = parse_powermetrics(path)
    n = len(samples)
    nz = {k: sum(1 for s in samples if s.get(k, 0.0) != 0.0)
          for k in ("cpu_mw", "ane_mw", "gpu_mw")}
    comb_eq_gpu = sum(1 for s in samples
                      if "combined_mw" in s and "gpu_mw" in s
                      and s["combined_mw"] == s["gpu_mw"])
    have_both = sum(1 for s in samples if "combined_mw" in s and "gpu_mw" in s)
    means = {k: round(statistics.fmean([s[k] for s in samples if k in s]), 2)
             for k in ("combined_mw", "gpu_mw") if any(k in s for s in samples)}
    return {"kind": "component_split", "capture": name, "n_samples": n,
            "nonzero": nz, "combined_eq_gpu": comb_eq_gpu,
            "combined_gpu_pairs": have_both, "means": means}


def jsonl_rows(path: Path) -> list[dict]:
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def extract_g_ratios() -> dict:
    g2 = g3 = None
    for p in sorted(W26.glob("results/w26-g2-*.jsonl")):
        g2 = jsonl_rows(p)
    for p in sorted(W26.glob("results/w26-g3-*.jsonl")):
        g3 = jsonl_rows(p)

    def ratios(rows: list[dict] | None) -> dict:
        for r in rows or []:
            if r.get("kind") == "summary" and "benches" in r:
                return {bench: round(float(d["ratio"]), 4)
                        for bench, d in r["benches"].items()}
        return {}
    return {"kind": "g_ratios", "g2": ratios(g2), "g3": ratios(g3)}


def rederive_confirm() -> dict:
    ledger = jsonl_rows(W26 / "results" / "w26-confirm-ledger.jsonl")
    segs = [r for r in ledger if r.get("kind") == "segment"]
    samples = parse_powermetrics(W26 / "results" / "powermetrics-w26-confirm.txt")
    reps = []
    for seg in segs:
        lo, hi = seg["t0_epoch"] + EDGE_TRIM_S, seg["t1_epoch"] - EDGE_TRIM_S
        vals = [s["combined_mw"] for s in samples
                if lo <= s["epoch"] <= hi and "combined_mw" in s]
        reps.append({"arm": seg["arm"], "rep": seg["rep"],
                     "binding": seg.get("binding", True),
                     "n": len(vals), "valid": len(vals) >= MIN_TRIMMED,
                     "mean_mw": round(statistics.fmean(vals), 3) if vals else None})
    med = {}
    for arm in ("off", "on"):
        means = [r["mean_mw"] for r in reps
                 if r["arm"] == arm and r["binding"] and r["valid"]]
        med[arm] = statistics.median(means)
    return {"kind": "confirm_rederived", "reps": reps,
            "median_off": round(med["off"], 3), "median_on": round(med["on"], 3),
            "ratio": round(med["on"] / med["off"], 4)}


def published_confirm() -> float | None:
    p = W26 / "results" / "w26-confirm-analysis.jsonl"
    for r in jsonl_rows(p):
        if r.get("kind") == "cell_summary" and r.get("cell") == "flood":
            return float(r["ratio_on_over_off"])
    return None


def flood_log_join() -> list[dict]:
    """Per-rep {arm, rep, session-tag, MiB, present, parse_ms/MiB} from the
    retained flood stderr logs, joined with the confirm energy rep means."""
    rows = []
    for log in sorted(W26.glob("logs/w26-flood-*-r*-*.stderr.log")):
        m = re.match(r"w26-flood-(on|off)-r(\d+)-(\d+)\.stderr\.log", log.name)
        if not m:
            continue
        arm, rep, tag = m.group(1), int(m.group(2)), m.group(3)
        tot: dict[str, float] = {}
        for line in log.read_text(errors="replace").splitlines():
            if "ftrace: seq=" not in line:
                continue
            for k, v in FT_KV.findall(line):
                if k in ("bytes", "parse_ms", "present"):
                    tot[k] = tot.get(k, 0.0) + float(v)
        mib = tot.get("bytes", 0.0) / (1024 * 1024)
        rows.append({"kind": "flood_rep", "arm": arm, "rep": rep, "session": tag,
                     "mib": round(mib, 1), "present": int(tot.get("present", 0)),
                     "parse_ms_per_mib": round(tot.get("parse_ms", 0.0) / mib, 4)
                     if mib else None})
    return rows


def session_parse_ratios(rows: list[dict]) -> list[dict]:
    out = []
    for tag in sorted({r["session"] for r in rows}):
        med = {}
        for arm in ("off", "on"):
            vals = [r["parse_ms_per_mib"] for r in rows
                    if r["session"] == tag and r["arm"] == arm
                    and r["parse_ms_per_mib"]]
            if vals:
                med[arm] = statistics.median(vals)
        if len(med) == 2:
            out.append({"kind": "session_parse_ratio", "session": tag,
                        "med_off": round(med["off"], 4), "med_on": round(med["on"], 4),
                        "ratio": round(med["on"] / med["off"], 4),
                        "n_per_arm": len([r for r in rows
                                          if r["session"] == tag and r["arm"] == "off"])})
    return out


def estimator_table(confirm: dict, joins: list[dict]) -> dict:
    reps = [r for r in confirm["reps"] if r["binding"] and r["valid"]]
    pooled = confirm["ratio"]
    by = {(r["arm"], r["rep"]): r["mean_mw"] for r in reps}
    paired = statistics.median([by[("on", i)] / by[("off", i)]
                                for i in range(1, 7)
                                if ("on", i) in by and ("off", i) in by])
    conf_session = max({r["session"] for r in joins})
    present = {(r["arm"], r["rep"]): r["present"] for r in joins
               if r["session"] == conf_session}
    reg = {"A": [], "B": []}
    for i in range(1, 7):
        regime = "A" if present.get(("on", i), 0) > 0 or present.get(("off", i), 0) > 0 else "B"
        if ("on", i) in by and ("off", i) in by:
            reg[regime].append((by[("off", i)], by[("on", i)]))

    def regime_ratio(pairs: list) -> float | None:
        if not pairs:
            return None
        return round(statistics.median([on for _, on in pairs]) /
                     statistics.median([off for off, _ in pairs]), 4)
    return {"kind": "estimators", "pooled_median6": pooled,
            "paired_median": round(paired, 4),
            "regime_present_gt0": regime_ratio(reg["A"]),
            "regime_present_eq0": regime_ratio(reg["B"]),
            "n_regime_A_pairs": len(reg["A"]), "n_regime_B_pairs": len(reg["B"])}


def main() -> int:
    out_rows: list[dict] = []
    for name, p in (("battery", W26 / "results" / "powermetrics-w26.txt"),
                    ("confirm", W26 / "results" / "powermetrics-w26-confirm.txt")):
        out_rows.append(component_split(name, p))
    g = extract_g_ratios()
    out_rows.append(g)
    confirm = rederive_confirm()
    out_rows.append(confirm)
    joins = flood_log_join()
    out_rows.extend(joins)
    out_rows.extend(session_parse_ratios(joins))
    out_rows.append(estimator_table(confirm, joins))

    published = published_confirm()
    checks = {
        "kind": "selfcheck",
        "g2_dense_expected_1.0077": g["g2"].get("dense_cells") == 1.0077,
        "g2_sync_expected_1.0047": g["g2"].get("sync_medium_cells") == 1.0047,
        "g3_dense_expected_0.9982": g["g3"].get("dense_cells") == 0.9982,
        "confirm_rederived_vs_published": confirm["ratio"] == published,
        "confirm_expected_1.1806": confirm["ratio"] == 1.1806,
        "published_value": published,
    }
    checks["all_pass"] = all(v is True for k, v in checks.items()
                             if k.endswith(("_1.0077", "_1.0047", "_0.9982",
                                            "_published", "_1.1806")))
    out_rows.append(checks)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "w") as f:
        for r in out_rows:
            f.write(json.dumps(r) + "\n")
    print(json.dumps({
        "component_split": [r for r in out_rows if r["kind"] == "component_split"],
        "g_ratios": g,
        "confirm": {k: confirm[k] for k in ("median_off", "median_on", "ratio")},
        "session_parse_ratios": [r for r in out_rows
                                 if r["kind"] == "session_parse_ratio"],
        "estimators": next(r for r in out_rows if r["kind"] == "estimators"),
        "selfcheck": checks}, indent=1))
    print(f"wrote {OUT}", file=sys.stderr)
    return 0 if checks["all_pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
