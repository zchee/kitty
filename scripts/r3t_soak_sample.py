#!/usr/bin/env python3.14
"""Soak sampler for the tmux pane-side OOB channel (M2 lane, ADR-0015).

The pane lane is now live on the daily binaries, so its remaining risk is not
throughput but stability: does a pane channel ever fail open in real use, and
how much of a channel-armed pane's output still crawls through the pty wall.
Both questions are answerable from two format variables, so this sampler only
issues read-only tmux queries against whatever servers happen to be running.

Modes:
  --sample                 one snapshot appended to today's JSONL
  --daemon                 snapshot loop on a drift-free schedule
  --aggregate [--date D]   roll a day's JSONL up into S-gate inputs (+ PNG)
  --emit-plist             write a launchd template for multi-day collection
  --selftest               assert the aggregator against a synthetic fixture

Pane channel states (tmux format.c format_cb_pane_kitty_oob):
  armed r=N b=N pty=N   channel live, handshake complete
  offered pty=N         channel live, handshake pending (stock tool in pane)
  fallback pty=N        channel gone after a fail-open
  none pty=N            never offered (kitty-oob-pane off, or respawn drop)
"""

import argparse
import json
import os
import re
import signal
import stat
import statistics
import subprocess
import sys
import time
from pathlib import Path

TMUX_BIN = os.environ.get("R3T_TMUX_BIN", "tmux")
SOCKET_DIR = Path(os.environ.get("TMUX_TMPDIR", "/private/tmp")) / f"tmux-{os.getuid()}"
SOAK_DIR = Path(__file__).resolve().parent.parent / ".omc" / "verify" / "r3t" / "soak"

# Format-var allowlist. Every field that can carry process arguments, an
# environment block or a working directory is deliberately absent
# (pane_start_command, pane_path, and `kitty @ ls` output): a soak artifact
# accumulates for days unattended, so it must stay safe to hand to anyone.
PANE_FIELDS = ("pane_id", "session_name", "window_index", "pane_index",
               "pane_pid", "pane_dead", "pane_current_command",
               "pane_kitty_oob")
CLIENT_FIELDS = ("client_name", "client_session", "client_kitty_oob")

ARMED_RE = re.compile(r"^armed r=(\d+) b=(\d+) pty=(\d+)$")
BARE_RE = re.compile(r"^(offered|fallback|none) pty=(\d+)$")

# Armed time never accrues across a gap longer than this, whatever the observed
# cadence works out to. A sleeping laptop must not bank hours of "armed".
GAP_CEILING_S = 900.0

# A window can pass every gate without having asked the channel to do anything.
# Below this exposure the right answer is INCONCLUSIVE, not ALL-PASS: either a
# MiB of channel traffic, or one sample of a program that is known to use the
# channel, has to be present before "nothing broke" carries weight.
EXPOSURE_MIN_BYTES = 1024 * 1024
CHANNEL_AWARE_COMMANDS = ("nvim", "vim")


def tmux_q(sock: str, *args: str, timeout: float = 10.0) -> str:
    """Run a read-only tmux query against one server, returning stdout."""
    r = subprocess.run([TMUX_BIN, "-L", sock, *args], capture_output=True,
                       text=True, timeout=timeout)
    return r.stdout if r.returncode == 0 else ""


def list_sockets() -> list[str]:
    """Names of live tmux server sockets in the per-uid socket directory."""
    if not SOCKET_DIR.is_dir():
        return []
    out = []
    for p in sorted(SOCKET_DIR.iterdir()):
        try:
            if stat.S_ISSOCK(p.stat().st_mode):
                out.append(p.name)
        except OSError:
            continue
    return out


def parse_pane_state(value: str) -> dict:
    """Decompose #{pane_kitty_oob} into a state plus its counters."""
    m = ARMED_RE.match(value)
    if m:
        return {"state": "armed", "oob_reads": int(m.group(1)),
                "oob_bytes": int(m.group(2)), "pty_reads": int(m.group(3))}
    m = BARE_RE.match(value)
    if m:
        return {"state": m.group(1), "oob_reads": 0, "oob_bytes": 0,
                "pty_reads": int(m.group(2))}
    # Zeroed counters even here: an unparsed value must not make the aggregator
    # trip over a missing key while it is reporting that the value was unparsed.
    return {"state": "unknown", "raw": value, "oob_reads": 0, "oob_bytes": 0,
            "pty_reads": 0}


def sample_once() -> dict:
    """One snapshot of every live server's pane and client channel state."""
    rec: dict = {"t": time.time(), "servers": []}
    pane_fmt = "\t".join(f"#{{{f}}}" for f in PANE_FIELDS)
    client_fmt = "\t".join(f"#{{{f}}}" for f in CLIENT_FIELDS)
    for sock in list_sockets():
        pid = tmux_q(sock, "display-message", "-p", "#{pid}").strip()
        if not pid.isdigit():
            continue
        srv: dict = {"socket": sock, "server_pid": int(pid), "panes": [],
                     "clients": []}
        for line in tmux_q(sock, "list-panes", "-a", "-F", pane_fmt).splitlines():
            parts = line.split("\t")
            if len(parts) != len(PANE_FIELDS):
                continue
            p = dict(zip(PANE_FIELDS, parts))
            p.update(parse_pane_state(p.pop("pane_kitty_oob")))
            p["pane_pid"] = int(p["pane_pid"]) if p["pane_pid"].isdigit() else -1
            srv["panes"].append(p)
        for line in tmux_q(sock, "list-clients", "-F", client_fmt).splitlines():
            parts = line.split("\t")
            if len(parts) != len(CLIENT_FIELDS):
                continue
            srv["clients"].append(dict(zip(CLIENT_FIELDS, parts)))
        rec["servers"].append(srv)
    return rec


def samples_path(date: str) -> Path:
    return SOAK_DIR / f"samples-{date}.jsonl"


def today() -> str:
    return time.strftime("%Y-%m-%d", time.localtime())


def append_sample(rec: dict) -> Path:
    SOAK_DIR.mkdir(parents=True, exist_ok=True)
    path = samples_path(time.strftime("%Y-%m-%d", time.localtime(rec["t"])))
    with path.open("a") as f:
        f.write(json.dumps(rec) + "\n")
    return path


def summarize_sample(rec: dict) -> str:
    hist: dict[str, int] = {}
    clients: dict[str, int] = {}
    for srv in rec["servers"]:
        for p in srv["panes"]:
            hist[p["state"]] = hist.get(p["state"], 0) + 1
        for c in srv["clients"]:
            st = c["client_kitty_oob"]
            clients[st] = clients.get(st, 0) + 1
    return (f"panes={hist or '{}'} clients={clients or '{}'} "
            f"servers={len(rec['servers'])}")


def run_daemon(interval: float, duration: float) -> int:
    """Sample on a drift-free schedule until the duration elapses."""
    stopping = {"flag": False}

    def stop(_signum, _frame):
        stopping["flag"] = True

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    t0 = time.monotonic()
    next_t = t0
    n = 0
    while not stopping["flag"] and time.monotonic() - t0 < duration:
        rec = sample_once()
        path = append_sample(rec)
        n += 1
        if n == 1 or n % 10 == 0:
            print(f"[soak] n={n} {summarize_sample(rec)} -> {path.name}",
                  flush=True)
        next_t += interval
        sleep_for = next_t - time.monotonic()
        while sleep_for > 0 and not stopping["flag"]:
            time.sleep(min(sleep_for, 1.0))
            sleep_for = next_t - time.monotonic()
    print(f"[soak] stopped after {n} samples, "
          f"{time.monotonic() - t0:.1f}s elapsed", flush=True)
    return 0


def load_samples(path: Path) -> list[dict]:
    if not path.exists():
        return []
    out = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line:
            out.append(json.loads(line))
    return out


def aggregate(recs: list[dict]) -> dict:
    """Roll snapshots up into the S-gate inputs.

    Panes are keyed by (socket, pane_id, pane_pid) so a respawn — which keeps
    pane_id but replaces the child and its channel — starts a fresh identity
    instead of registering as a state transition.
    """
    if not recs:
        return {"error": "no samples"}
    recs = sorted(recs, key=lambda r: r["t"])
    times = [r["t"] for r in recs]
    gaps = [b - a for a, b in zip(times, times[1:])]
    cadence = statistics.median(gaps) if gaps else 0.0
    # Three cadences, but never more than the absolute ceiling: the median
    # itself grows when a laptop sleeps through most of the intervals, so a
    # purely relative rule would credit the sleep as armed time.
    max_gap = min(3 * cadence, GAP_CEILING_S) if cadence else GAP_CEILING_S

    per_key: dict[str, list[tuple[float, dict]]] = {}
    state_series: list[dict] = []
    client_hist: dict[str, int] = {}
    server_pids: dict[str, set[int]] = {}
    server_last_seen: dict[str, float] = {}
    server_first_appearance: dict[str, float] = {}
    last_record_keys: set[str] = set()
    last_record_sockets: set[str] = set()
    for r in recs:
        counts: dict[str, int] = {}
        for srv in r["servers"]:
            server_pids.setdefault(srv["socket"], set()).add(srv["server_pid"])
            server_first_appearance.setdefault(srv["socket"], r["t"])
            server_last_seen[srv["socket"]] = r["t"]
            for p in srv["panes"]:
                key = f"{srv['socket']}\t{p['pane_id']}\t{p['pane_pid']}"
                per_key.setdefault(key, []).append((r["t"], p))
                counts[p["state"]] = counts.get(p["state"], 0) + 1
            for c in srv["clients"]:
                st = c["client_kitty_oob"]
                client_hist[st] = client_hist.get(st, 0) + 1
        state_series.append({"t": r["t"], **counts})
    for srv in recs[-1]["servers"]:
        last_record_sockets.add(srv["socket"])
        for p in srv["panes"]:
            last_record_keys.add(f"{srv['socket']}\t{p['pane_id']}\t{p['pane_pid']}")

    fail_open = []
    vanished = []
    broken_keys = set()
    armed_seconds = 0.0
    longest_streak = 0.0
    ever_armed_samples = 0
    ever_armed_nonarmed = 0
    pane_reports = []
    for key, seq in per_key.items():
        states = [p["state"] for _, p in seq]
        ever_armed = "armed" in states
        if ever_armed:
            ever_armed_samples += len(states)
            ever_armed_nonarmed += sum(1 for s in states if s != "armed")
        if "fallback" in states:
            broken_keys.add(key)
        streak = 0.0
        for (t0, p0), (t1, _p1) in zip(seq, seq[1:]):
            dt = t1 - t0
            if p0["state"] == "armed" and dt <= max_gap:
                armed_seconds += dt
                streak += dt
                longest_streak = max(longest_streak, streak)
            else:
                streak = 0.0
            # Any armed pane that stops being armed lost its channel. Only
            # `fallback` names the fail-open explicitly, but a kill-switch flip
            # or a respawn drop lands in `none`, and a format change lands in
            # `unknown` — all of them are the failure this gate exists to catch.
            if p0["state"] == "armed" and _p1["state"] != "armed":
                fail_open.append({"key": key, "at": t1,
                                  "to_state": _p1["state"],
                                  "oob_bytes_when_armed": p0.get("oob_bytes"),
                                  "cmd": _p1.get("pane_current_command")})
                broken_keys.add(key)
        # A pane killed mid-window stops appearing, so a fail-open in its last
        # unsampled seconds is unobservable. Count those cases instead of
        # letting them read as a clean armed exit.
        if key not in last_record_keys and seq[-1][1]["state"] == "armed":
            vanished.append({"key": key, "last_seen": seq[-1][0],
                             "cmd": seq[-1][1].get("pane_current_command")})
        first, last = seq[0][1], seq[-1][1]

        def delta(field: str, first: dict = first, last: dict = last) -> int:
            return last.get(field, 0) - first.get(field, 0)

        if ever_armed:
            pane_reports.append({
                "key": key, "cmd": last.get("pane_current_command"),
                "samples": len(seq), "states": sorted(set(states)),
                "oob_bytes_delta": delta("oob_bytes"),
                "pty_reads_delta": delta("pty_reads"),
                "oob_reads_delta": delta("oob_reads")})

    rate = (ever_armed_nonarmed / ever_armed_samples) if ever_armed_samples else 0.0
    window_s = times[-1] - times[0]
    hist_total: dict[str, int] = {}
    for row in state_series:
        for k, v in row.items():
            if k != "t":
                hist_total[k] = hist_total.get(k, 0) + v
    # A server that stops answering is the crash S-G4 exists to exclude; it
    # leaves no pid change behind, so it has to be caught by absence.
    servers_vanished = {s: t for s, t in server_last_seen.items()
                        if s not in last_record_sockets}
    unknown_samples = hist_total.get("unknown", 0)
    channel_bytes = sum(max(p["oob_bytes_delta"], 0) for p in pane_reports)
    aware_samples = sum(1 for _k, seq in per_key.items() for _t, p in seq
                        if any(c in (p.get("pane_current_command") or "")
                               for c in CHANNEL_AWARE_COMMANDS))
    out = {
        "samples": len(recs),
        "window_s": window_s,
        "window_min": window_s / 60.0,
        "cadence_s": cadence,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(times[0])),
        "ended_at": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(times[-1])),
        "panes_tracked": len(per_key),
        "ever_armed_panes": len(pane_reports),
        "fail_open_events": len(fail_open),
        "fail_open_detail": fail_open,
        "armed_panes_vanished_unobserved": len(vanished),
        "armed_panes_vanished_detail": vanished,
        "broken_panes": len(broken_keys),
        "pty_fallback_rate": rate,
        "armed_seconds": armed_seconds,
        "armed_longest_streak_s": longest_streak,
        "pane_state_samples": hist_total,
        "client_state_samples": client_hist,
        "server_pid_changes": {s: sorted(p) for s, p in server_pids.items()
                               if len(p) > 1},
        "servers_vanished": servers_vanished,
        "server_transient_absences": {
            s: sum(1 for r in recs
                   if server_first_appearance[s] < r["t"] < server_last_seen[s]
                   and s not in {v["socket"] for v in r["servers"]})
            for s in server_last_seen},
        "unknown_state_samples": unknown_samples,
        "in_window_channel_bytes": channel_bytes,
        "channel_aware_command_samples": aware_samples,
        "max_gap_s": max_gap,
        "armed_pane_reports": pane_reports,
        "series": state_series,
    }
    srv_break = len(out["server_pid_changes"]) + len(servers_vanished)
    out["s_gates"] = {
        "S_G1_no_fail_open": {"value": len(fail_open), "gate": 0,
                              "pass": len(fail_open) == 0},
        "S_G2_no_broken_panes": {"value": len(broken_keys), "gate": 0,
                                 "pass": len(broken_keys) == 0},
        "S_G3_pty_fallback_rate": {"value": rate, "gate": 0.02,
                                   "pass": rate <= 0.02},
        "S_G4_server_continuity": {"value": srv_break, "gate": 0,
                                   "pid_changes": out["server_pid_changes"],
                                   "vanished": servers_vanished,
                                   "pass": srv_break == 0},
        "S_G5_states_understood": {"value": unknown_samples, "gate": 0,
                                   "pass": unknown_samples == 0},
    }
    # A window that observed no armed pane, or whose states could not be
    # parsed, has nothing to be green about: silence must not read as a pass.
    void_reasons = []
    if not pane_reports:
        void_reasons.append("no armed pane observed")
    if unknown_samples:
        void_reasons.append(f"{unknown_samples} unparsed state samples")
    out["void_reasons"] = void_reasons
    # Passing every gate while nothing used the channel is not evidence that
    # the channel works; it is evidence that nothing asked.
    exposure_ok = (channel_bytes >= EXPOSURE_MIN_BYTES or aware_samples > 0)
    out["exposure_floor"] = {
        "min_bytes": EXPOSURE_MIN_BYTES,
        "in_window_channel_bytes": channel_bytes,
        "channel_aware_command_samples": aware_samples,
        "met": exposure_ok}
    if void_reasons:
        out["verdict"] = "VOID"
    elif not all(g["pass"] for g in out["s_gates"].values()):
        out["verdict"] = "FAIL"
    elif not exposure_ok:
        out["verdict"] = "INCONCLUSIVE"
    else:
        out["verdict"] = "ALL-PASS"
    return out


def emit_png(rollup: dict, date: str) -> Path | None:
    """Timeseries of pane channel states plus the S-gate panel."""
    series = rollup.get("series") or []
    if not series:
        return None
    t0 = series[0]["t"]
    states = ("armed", "offered", "fallback", "none")
    dat = SOAK_DIR / f"soak-{date}.dat"
    dat.write_text("\n".join(
        " ".join([f"{(row['t'] - t0) / 60.0:.3f}"]
                 + [str(row.get(s, 0)) for s in states])
        for row in series) + "\n")
    g = rollup["s_gates"]
    dat2 = SOAK_DIR / f"soak-{date}-gates.dat"
    bars = [("fail-open (=0)", g["S_G1_no_fail_open"]["value"]),
            ("broken panes (=0)", g["S_G2_no_broken_panes"]["value"]),
            ("pty fallback % (<=2)", g["S_G3_pty_fallback_rate"]["value"] * 100),
            ("srv breaks (=0)", g["S_G4_server_continuity"]["value"]),
            ("unparsed states (=0)", g["S_G5_states_understood"]["value"]),
            ("armed panes vanished",
             rollup.get("armed_panes_vanished_unobserved", 0))]
    dat2.write_text("\n".join(f'{i} {v:.4f} "{n}"'
                              for i, (n, v) in enumerate(bars)) + "\n")
    png = SOAK_DIR.parent / f"r3t-soak-{date}.png"
    gp = SOAK_DIR / f"soak-{date}.gp"
    gp.write_text(f"""set terminal pngcairo size 1100,760 font 'Helvetica,12'
set output '{png}'
set multiplot layout 2,1 title 'M2 pane-lane soak {date} \
({rollup["window_min"]:.1f} min, {rollup["samples"]} samples, \
cadence {rollup["cadence_s"]:.0f}s) — {rollup["verdict"]}: \
{rollup["exposure_floor"]["in_window_channel_bytes"]} channel bytes in window, \
floor {rollup["exposure_floor"]["min_bytes"]}'
set key outside right
set xlabel 'minutes into window'
set ylabel 'panes'
set grid ytics
set yrange [0:*]
plot '{dat}' using 1:2 with lines lw 2 lc rgb '#2ca02c' title 'armed', \\
     '{dat}' using 1:3 with lines lw 2 lc rgb '#1f77b4' title 'offered', \\
     '{dat}' using 1:4 with lines lw 2 lc rgb '#d62728' title 'fallback', \\
     '{dat}' using 1:5 with lines lw 2 lc rgb '#7f7f7f' title 'none'
unset key
set xlabel ''
set ylabel 'value (lower is better)'
set xrange [-0.6:5.6]
set yrange [0:*]
set boxwidth 0.5
set style fill solid 0.55
plot '{dat2}' using 1:2:xtic(3) with boxes lc rgb '#9467bd' notitle, \\
     '{dat2}' using 1:($2+0.05):(sprintf('%.2f', $2)) with labels font ',10' notitle
unset multiplot
""")
    try:
        subprocess.run(["gnuplot", str(gp)], check=True, capture_output=True,
                       timeout=30)
    except (subprocess.CalledProcessError, FileNotFoundError,
            subprocess.TimeoutExpired) as e:
        print(f"[soak] gnuplot failed: {e}", file=sys.stderr)
        return None
    return png if png.exists() else None


PLIST_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>io.zchee.r3t-soak</string>
  <key>ProgramArguments</key>
  <array>
    <string>{python}</string>
    <string>{script}</string>
    <string>--sample</string>
  </array>
  <key>StartInterval</key><integer>{interval}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>{soak}/launchd.err</string>
</dict>
</plist>
"""


def emit_plist(interval: int) -> Path:
    """Write (never install) a launchd template for multi-day collection."""
    SOAK_DIR.mkdir(parents=True, exist_ok=True)
    path = SOAK_DIR / "io.zchee.r3t-soak.plist"
    path.write_text(PLIST_TEMPLATE.format(
        python=sys.executable, script=str(Path(__file__).resolve()),
        interval=interval, soak=str(SOAK_DIR)))
    (SOAK_DIR / "README-launchd.md").write_text(f"""# Multi-day soak collection

This template is NOT installed. To continue the soak across days:

    cp {path} ~/Library/LaunchAgents/
    launchctl load ~/Library/LaunchAgents/io.zchee.r3t-soak.plist

It runs `--sample` every {interval}s (one read-only tmux query per live
server) and appends to `samples-<date>.jsonl` in this directory. Roll a day up
with:

    {sys.executable} {Path(__file__).resolve()} --aggregate --date YYYY-MM-DD

To stop and remove:

    launchctl unload ~/Library/LaunchAgents/io.zchee.r3t-soak.plist
    rm ~/Library/LaunchAgents/io.zchee.r3t-soak.plist
""")
    return path


def selftest() -> int:
    """Assert the aggregator against a synthetic fail-open transition."""
    def rec(t, state, pty, oob_bytes=0, oob_reads=0, pid=100):
        return {"t": t, "servers": [{"socket": "s", "server_pid": 7, "clients": [
            {"client_name": "/dev/ttys000", "client_session": "0",
             "client_kitty_oob": "armed"}], "panes": [
            {"pane_id": "%1", "session_name": "x", "window_index": "0",
             "pane_index": "0", "pane_pid": pid, "pane_dead": "0",
             "pane_current_command": "zsh", "state": state,
             "oob_reads": oob_reads, "oob_bytes": oob_bytes,
             "pty_reads": pty}]}]}

    recs = [rec(0, "armed", 10, 1000, 5), rec(15, "armed", 12, 2000, 9),
            rec(30, "fallback", 40), rec(45, "fallback", 90)]
    a = aggregate(recs)
    checks = {
        "fail_open_events == 1": a["fail_open_events"] == 1,
        "broken_panes == 1": a["broken_panes"] == 1,
        "armed_seconds == 30": abs(a["armed_seconds"] - 30.0) < 1e-6,
        "longest_streak == 30": abs(a["armed_longest_streak_s"] - 30.0) < 1e-6,
        "pty_fallback_rate == 0.5": abs(a["pty_fallback_rate"] - 0.5) < 1e-9,
        "cadence == 15": abs(a["cadence_s"] - 15.0) < 1e-9,
        "verdict FAIL": a["verdict"] == "FAIL",
        "S_G3 fails at 0.5": not a["s_gates"]["S_G3_pty_fallback_rate"]["pass"],
    }
    # A clean window with a respawn (new pane_pid) must not count a transition.
    recs2 = [rec(0, "armed", 10, 1000, 5), rec(15, "armed", 11, 1500, 7),
             rec(30, "offered", 3, pid=200), rec(45, "armed", 4, 500, 2, pid=200)]
    b = aggregate(recs2)
    checks["respawn is not a fail-open"] = b["fail_open_events"] == 0
    checks["respawn splits identities"] = b["panes_tracked"] == 2
    checks["ever-armed rate counts both generations"] = (
        abs(b["pty_fallback_rate"] - 0.25) < 1e-9)
    # An armed pane that stops appearing (killed) hides whatever happened next.
    empty = {"t": 0.0, "servers": [{"socket": "s", "server_pid": 7,
                                    "clients": [], "panes": []}]}
    gone = [rec(0, "armed", 1, 100, 1), rec(15, "armed", 2, 200, 2),
            {**empty, "t": 30.0}, {**empty, "t": 45.0}, {**empty, "t": 60.0}]
    c = aggregate(gone)
    checks["vanished armed pane is flagged"] = (
        c["armed_panes_vanished_unobserved"] == 1)
    checks["vanished pane is not a fail-open"] = c["fail_open_events"] == 0
    still = aggregate([rec(0, "armed", 1, 100, 1), rec(15, "armed", 2, 200, 2)])
    checks["pane present at window end is not vanished"] = (
        still["armed_panes_vanished_unobserved"] == 0)
    # armed -> none is a channel loss too (kill-switch flip or respawn drop).
    to_none = aggregate([rec(0, "armed", 1, 100, 1), rec(15, "armed", 2, 200, 2),
                         rec(30, "none", 3), rec(45, "none", 4)])
    checks["armed->none counts as fail-open"] = to_none["fail_open_events"] == 1
    checks["armed->none marks the pane broken"] = to_none["broken_panes"] == 1
    checks["armed->none fails the window"] = to_none["verdict"] == "FAIL"
    # An unparsed state means the instrument, not the lane, is the unknown.
    unk = [rec(0, "armed", 1, 100, 1), rec(15, "unknown", 0)]
    u = aggregate(unk)
    checks["unknown state is counted"] = u["unknown_state_samples"] == 1
    checks["unknown state voids the window"] = u["verdict"] == "VOID"
    # A window with nothing armed has nothing to be green about.
    idle = [{"t": float(i * 15), "servers": [{"socket": "s", "server_pid": 7,
             "clients": [], "panes": [
                 {"pane_id": "%9", "session_name": "x", "window_index": "0",
                  "pane_index": "0", "pane_pid": 900, "pane_dead": "0",
                  "pane_current_command": "zsh", "state": "none",
                  "oob_reads": 0, "oob_bytes": 0, "pty_reads": i}]}]}
            for i in range(6)]
    idl = aggregate(idle)
    checks["no armed pane voids the window"] = idl["verdict"] == "VOID"
    checks["void reason is recorded"] = bool(idl["void_reasons"])
    # A server that stops answering is a crash, even without a pid change.
    srv_gone = [rec(0, "armed", 1, 100, 1), rec(15, "armed", 2, 200, 2),
                {"t": 30.0, "servers": []}, {"t": 45.0, "servers": []},
                {"t": 60.0, "servers": []}]
    sg = aggregate(srv_gone)
    checks["vanished server fails S-G4"] = (
        not sg["s_gates"]["S_G4_server_continuity"]["pass"])
    restart = [rec(0, "armed", 1, 100, 1), rec(15, "armed", 2, 200, 2)]
    restart[1]["servers"][0]["server_pid"] = 8
    checks["server pid change fails S-G4"] = (
        not aggregate(restart)["s_gates"]["S_G4_server_continuity"]["pass"])
    # Gates green but nothing used the channel: INCONCLUSIVE, not ALL-PASS.
    thin = aggregate([rec(0, "armed", 1, 1000, 1), rec(15, "armed", 2, 2000, 2)])
    checks["low exposure is inconclusive"] = thin["verdict"] == "INCONCLUSIVE"
    checks["exposure floor is reported"] = (
        thin["exposure_floor"]["met"] is False
        and thin["exposure_floor"]["in_window_channel_bytes"] == 1000)
    fat = aggregate([rec(0, "armed", 1, 0, 1),
                     rec(15, "armed", 2, 2 * 1024 * 1024, 2)])
    checks["a MiB of channel traffic clears the floor"] = fat["verdict"] == "ALL-PASS"
    aware = [rec(0, "armed", 1, 10, 1), rec(15, "armed", 2, 20, 2)]
    aware[1]["servers"][0]["panes"][0]["pane_current_command"] = "nvim"
    checks["a channel-aware program clears the floor"] = (
        aggregate(aware)["verdict"] == "ALL-PASS")
    # Sleep must not be banked as armed time even when it dominates the cadence.
    sleepy = [rec(0, "armed", 1, 100, 1), rec(36000, "armed", 2, 200, 2),
              rec(72000, "armed", 3, 300, 3), rec(108000, "armed", 4, 400, 4)]
    sl = aggregate(sleepy)
    checks["long gaps never credit armed time"] = sl["armed_seconds"] == 0.0
    checks["gap ceiling is applied"] = sl["max_gap_s"] == GAP_CEILING_S
    for name, ok in checks.items():
        print(f"  {'PASS' if ok else 'FAIL'}  {name}")
    bad = [n for n, ok in checks.items() if not ok]
    print(f"[soak] selftest {'PASS' if not bad else 'FAIL: ' + str(bad)}")
    return 0 if not bad else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", action="store_true", help="one snapshot")
    ap.add_argument("--daemon", action="store_true", help="snapshot loop")
    ap.add_argument("--interval", type=float, default=15.0)
    ap.add_argument("--duration", type=float, default=1800.0)
    ap.add_argument("--aggregate", action="store_true")
    ap.add_argument("--date", default=None)
    ap.add_argument("--no-png", action="store_true")
    ap.add_argument("--emit-plist", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if args.emit_plist:
        print(f"[soak] wrote {emit_plist(int(args.interval))} (not installed)")
        return 0
    if args.sample:
        rec = sample_once()
        path = append_sample(rec)
        print(f"[soak] {summarize_sample(rec)} -> {path}")
        return 0
    if args.daemon:
        return run_daemon(args.interval, args.duration)
    if args.aggregate:
        date = args.date or today()
        roll = aggregate(load_samples(samples_path(date)))
        if "error" in roll:
            print(f"[soak] {roll['error']} for {date}", file=sys.stderr)
            return 1
        out = SOAK_DIR / f"rollup-{date}.json"
        out.write_text(json.dumps(roll, indent=1) + "\n")
        png = None if args.no_png else emit_png(roll, date)
        brief = {k: roll[k] for k in ("samples", "window_min", "cadence_s",
                                      "panes_tracked", "ever_armed_panes",
                                      "fail_open_events", "broken_panes",
                                      "pty_fallback_rate", "armed_seconds",
                                      "verdict")}
        print(json.dumps(brief, indent=1))
        print(f"[soak] rollup -> {out}")
        print(f"[soak] png -> {png}")
        return 0
    ap.error("pick one of --sample/--daemon/--aggregate/--emit-plist/--selftest")
    return 2


if __name__ == "__main__":
    sys.exit(main())
