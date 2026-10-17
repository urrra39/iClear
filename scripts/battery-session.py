#!/usr/bin/env python3
"""Resumable E2 evidence collection. No Active mode and no pressure workload.

One complete randomized pair per invocation; recharge only between pairs. Incomplete
pairs never enter the interval. B1 needs different fixtures/modes and is not measured.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import random
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


def save(path, value):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def fingerprint(app, lab):
    files = [app / "Contents" / name for name in
             ("Helpers/icleard", "Helpers/icbrake", "MacOS/iClear")]
    files += [lab, lab.parent / "ic-hog"]
    return {str(i): hashlib.sha256(path.read_bytes()).hexdigest() for i, path in enumerate(files)}


def parse_pair(text):
    if "INVALID" in text or re.search(r"^stopped:", text, re.MULTILINE):
        raise ValueError("incomplete or invalid pair; raw log retained")
    found = re.findall(r"pair 1 (running|stopped): drain (-?[0-9.]+) W", text)
    if len(found) != 2 or {arm for arm, _ in found} != {"running", "stopped"}:
        raise ValueError("missing paired drain observations")
    arms = {arm: float(watts) for arm, watts in found}
    if not all(math.isfinite(w) and w > 0 for w in arms.values()):
        raise ValueError("non-positive or non-finite discharge; inspect raw counters")
    return arms


def summary(state):
    pairs = [p["watts"]["running"] - p["watts"]["stopped"] for p in state["results"] if p["status"] == "valid"]
    result = {"valid_pairs": len(pairs), "planned_pairs": 6, "status": "INCONCLUSIVE"}
    if len(pairs) == 6:
        mean = sum(pairs) / 6
        sd = math.sqrt(sum((p - mean) ** 2 for p in pairs) / 5)
        half = 2.5705818366 * sd / math.sqrt(6)
        result.update(mean_added_watts=mean, lower95=mean - half, upper95=mean + half,
                      status="PASS" if mean + half <= 0.20 else "FAIL")
        if mean - half <= 0 <= mean + half:
            result["interpretation"] = "no measurable difference at this resolution"
    return result


def stop_group(process):
    """Stop only the fresh session we launched, including watchdog descendants."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        time.sleep(2)
    process.wait(timeout=5)


def run_pair(state, state_path, app, lab):
    if sys.platform != "darwin":
        raise ValueError("BLOCKED: a physical battery-powered Mac is required")
    if state["fingerprint"] != fingerprint(app, lab):
        raise ValueError("build/workload changed; create a new plan instead of mixing evidence")
    if any(r["status"] == "running" for r in state["results"]):
        raise ValueError("previous collector did not close cleanly; inspect its recorded process group and retain this plan")
    index = sum(r["status"] == "valid" for r in state["results"])
    if index == 6:
        return
    preflight = json.loads(subprocess.check_output([str(lab), "battery-preflight"], text=True, timeout=15))
    if not preflight["ready"]:
        raise ValueError("BLOCKED: " + "; ".join(preflight["blocked"]))
    previous = next((r["preflight"] for r in state["results"] if r["status"] == "valid"), None)
    if previous and (previous["hardware"] != preflight["hardware"] or
                     previous["conditions"]["lowPowerMode"] != preflight["conditions"]["lowPowerMode"]):
        raise ValueError("hardware, OS or Low Power Mode changed; create a new plan")
    work = state_path.parent / ("attempt-%03d" % (len(state["results"]) + 1))
    work.mkdir()  # never overwrite an earlier attempt
    raw = work / "raw.txt"
    entry = {"pair": index + 1, "status": "running", "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
             "preflight": preflight, "raw": str(raw.relative_to(state_path.parent))}
    state["results"].append(entry)
    save(state_path, state)
    process = None
    # macOS Unix sockets are limited to 104 bytes. Evidence may live in a long path,
    # but the isolated daemon's home must stay short.
    runtime = Path(tempfile.mkdtemp(prefix="ic-e-", dir="/tmp"))
    entry["runtime"] = str(runtime)
    try:
        with (work / "console.txt").open("w") as console:
            process = subprocess.Popen(
                [str(lab), "battery-ab", "--app", str(app), "--pairs", "1", "--block", "20",
                 "--running-first", str(state["running_first"][index]).lower(), "--out", str(raw)],
                env={**os.environ, "ICLEAR_ENERGY_ROOT": str(runtime)},
                stdout=console, stderr=subprocess.STDOUT, start_new_session=True)
            entry["process_group"] = process.pid
            save(state_path, state)
            code = process.wait(timeout=44 * 60)
        if code != 0:
            raise ValueError("collector exited with status %d" % code)
        entry["watts"] = parse_pair(raw.read_text())
        entry["raw_sha256"] = hashlib.sha256(raw.read_bytes()).hexdigest()
        entry["status"] = "valid"
    except (Exception, KeyboardInterrupt) as error:
        entry.update(status="invalid", reason=str(error) or "interrupted")
    finally:
        if process is not None:
            stop_group(process)
        # Runtime contains only this Observe collector's temporary state, never evidence.
        shutil.rmtree(runtime, ignore_errors=True)
        save(state_path, state)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["plan", "status", "run"])
    parser.add_argument("directory", type=Path)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--lab", type=Path)
    parser.add_argument("--source-sha")
    parser.add_argument("--brightness-percent", type=int)
    args = parser.parse_args()
    state_path = args.directory.resolve() / "session.json"
    if args.command == "plan":
        if args.app is None or args.lab is None or not re.fullmatch(r"[0-9a-f]{40}", args.source_sha or ""):
            parser.error("plan requires --app, --lab and --source-sha (40 hex characters)")
        if args.brightness_percent is None or not 0 <= args.brightness_percent <= 100:
            parser.error("record the fixed screen brightness using --brightness-percent 0..100")
        args.directory.mkdir(parents=True, exist_ok=False)
        state = {"protocol": "E2-session-v1", "source_sha": args.source_sha,
                 "brightness_percent": args.brightness_percent, "fingerprint": fingerprint(args.app, args.lab),
                 "running_first": [bool(random.SystemRandom().getrandbits(1)) for _ in range(6)], "results": []}
        save(state_path, state)
    else:
        state = json.loads(state_path.read_text())
        if state.get("protocol") != "E2-session-v1":
            raise ValueError("unsupported protocol; do not modify this evidence")
        if args.command == "run":
            if args.app is None or args.lab is None:
                parser.error("run requires the same --app and --lab as the plan")
            if args.brightness_percent != state["brightness_percent"]:
                parser.error("confirm the unchanged brightness using --brightness-percent from the plan")
            if sys.platform != "darwin":
                raise ValueError("BLOCKED: a physical battery-powered Mac is required")
            # Excludes concurrent collectors, with no dependency on a PID lock heuristic.
            import fcntl
            with state_path.with_suffix(".lock").open("w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                state = json.loads(state_path.read_text())
                run_pair(state, state_path, args.app.resolve(), args.lab.resolve())
    print(json.dumps(summary(state), indent=2))


if __name__ == "__main__":
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt("interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
