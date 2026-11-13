#!/usr/bin/env python3
"""Drive repeatable Scope Dev stress cases and keep machine-readable evidence."""

import hashlib
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import stress_image


ROOT = stress_image.ROOT
BASE = stress_image.BASE
APP = ROOT / "build/DerivedData/Build/Products/Debug/Scope Dev.app/Contents/MacOS/Scope Dev"
HOOK = ROOT / "build/devhook"
STATUS = ROOT / "build/stress_status"
RUNS = BASE / "runs"
LOW_SPACE_RUNS = BASE / "low-space-runs"
TERMINAL = {"done", "failed", "cancelled"}
ACTIVE_RUN_ID = None


def hash_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def hash_small_tree(folder):
    digest = hashlib.sha256()
    for path in sorted(folder.iterdir()):
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
    return digest.hexdigest()


def hook(command):
    subprocess.run([str(HOOK), "--stress-run-id", ACTIVE_RUN_ID, command], check=True, timeout=15)


def status():
    last_error = None
    for _ in range(3):
        try:
            return json.loads(subprocess.check_output(
                [str(STATUS), ACTIVE_RUN_ID], timeout=8, stderr=subprocess.PIPE))
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            last_error = error
            time.sleep(0.2)
    raise last_error


def wait_for(predicate, timeout, sample):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = status()
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            time.sleep(0.35)
            continue
        sample(last)
        if predicate(last):
            return last
        time.sleep(0.35)
    raise RuntimeError(f"Timed out waiting for Scope Dev; last status: {last}")


def latest_operation(previous_ids, timeout, sample, cancel_at=None, pause_at=None, events=None):
    found = wait_for(lambda state: any(op["id"] not in previous_ids for op in state["operations"]),
                     15, sample)
    operation_id = next(op["id"] for op in found["operations"] if op["id"] not in previous_ids)
    deadline = time.monotonic() + timeout
    cancelled = False
    pause_sent = False
    resume_sent = False
    while time.monotonic() < deadline:
        snapshot = status()
        sample(snapshot)
        operation = next((op for op in snapshot["operations"] if op["id"] == operation_id), None)
        if operation is None:
            raise RuntimeError(f"Operation {operation_id} disappeared")
        total = operation["bytesTotal"]
        fraction = operation["bytesDone"] / total if total > 0 else 0
        if pause_at is not None and not pause_sent and operation["state"] == "running" and fraction >= pause_at:
            hook("pause")
            pause_sent = True
        if pause_sent and not resume_sent and operation["state"] == "paused":
            if events is not None:
                events["paused"] = True
            hook("resume")
            resume_sent = True
        if resume_sent and operation["state"] == "running" and events is not None:
            events["resumed"] = True
        if cancel_at is not None and not cancelled and operation["state"] == "running":
            if (pause_at is None or (events is not None and events.get("resumed"))) and fraction >= cancel_at:
                hook("cancel")
                cancelled = True
        if operation["state"] in TERMINAL:
            return operation, cancelled
        time.sleep(0.35)
    raise RuntimeError(f"Operation {operation_id} did not reach a terminal state")


def partials(root):
    return [str(path) for path in root.rglob(".scope-partial-*")]


def rss_kib(pid):
    try:
        return int(subprocess.check_output(["/bin/ps", "-o", "rss=", "-p", str(pid)]).strip())
    except (ValueError, subprocess.CalledProcessError):
        return None


def run_once(index):
    global ACTIVE_RUN_ID
    stress_image.reset()
    volumes = stress_image.checked_volumes()
    source = Path(volumes[stress_image.SOURCE_NAME]["mount"]) / "ScopeStress/fixtures"
    target = Path(volumes[stress_image.TARGET_NAME]["mount"]) / "ScopeStress/target"
    manifest = json.loads(stress_image.MANIFEST.read_text())
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]
    ACTIVE_RUN_ID = run_id
    folder = RUNS / run_id
    folder.mkdir(parents=True)
    samples = folder / "samples.jsonl"
    results = []
    last_snapshot = None
    started_at = time.time()
    env = dict(os.environ, SCOPE_STRESS_RUN_ID=run_id)
    args = [str(APP), "--scope-stress-image", str(stress_image.IMAGE),
            "--scope-stress-source", volumes[stress_image.SOURCE_NAME]["uuid"],
            "--scope-stress-target", volumes[stress_image.TARGET_NAME]["uuid"]]
    process = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def sample(snapshot):
        nonlocal last_snapshot
        last_snapshot = snapshot
        record = {"time": time.time(), "status": snapshot, "rssKiB": rss_kib(process.pid),
                  "targetFreeBytes": shutil.disk_usage(target).free}
        with samples.open("a") as output:
            output.write(json.dumps(record, sort_keys=True) + "\n")
    def record(name, expected, observed, passed, seconds=None):
        results.append({"case": name, "expected": expected, "observed": observed,
                        "passed": bool(passed), "seconds": seconds})
        if not passed:
            raise RuntimeError(f"{name}: expected {expected}; observed {observed}")
    try:
        wait_for(lambda s: s["runID"] == run_id and s["location"] == stress_image.SOURCE_NAME,
                 20, sample)
        sentinel = BASE / "outside-sentinel.txt"
        hook("go:" + str(sentinel))
        state = status()
        sample(state)
        sentinel_hash = hash_file(sentinel)
        record("outside navigation", "source stays open and sentinel hash unchanged",
               {"location": state["location"], "sha256": sentinel_hash},
               state["location"] == stress_image.SOURCE_NAME
               and sentinel_hash == manifest["outside_sentinel_sha256"])
        hook("dismiss")

        started = time.monotonic()
        hook("go:" + str(source / "wide"))
        state = wait_for(lambda s: s["location"] == "wide" and s["itemsShown"] == 100_000,
                         45, sample)
        wide_seconds = time.monotonic() - started
        record("100k listing", "100000 items within 45 seconds",
               {"items": state["itemsShown"], "seconds": wide_seconds}, True, wide_seconds)

        hook("go:" + str(source / "transfer"))
        wait_for(lambda s: s["location"] == "transfer" and s["itemsShown"] == 5, 15, sample)
        before = {op["id"] for op in status()["operations"]}
        hook("select:large-0.bin")
        hook("command:duplicate")
        duplicate, _ = latest_operation(before, 120, sample)
        candidates = list((source / "transfer").glob("large-0*"))
        copies = [path for path in candidates if path.name != "large-0.bin"]
        good_copy = (duplicate["state"] == "done" and len(copies) == 1
                     and hash_file(copies[0]) == manifest["transfer_large_sha256"]["large-0.bin"])
        record("same-volume duplicate", "one exact copy", duplicate, good_copy)
        copy_info = copies[0].lstat()
        before = {op["id"] for op in status()["operations"]}
        hook("undo")
        undone, _ = latest_operation(before, 120, sample)
        record("duplicate undo", "copy removed", undone,
               undone["state"] == "done" and not copies[0].exists())
        cleaned_copy = stress_image.remove_owned_trash_item(
            volumes[stress_image.SOURCE_NAME], (copy_info.st_dev, copy_info.st_ino))
        record("duplicate Trash cleanup", "only the verified trashed duplicate removed",
               {"inode": copy_info.st_ino, "removed": cleaned_copy}, cleaned_copy)

        # Cancel the full tree after measurable cross-volume progress.
        hook("go:" + str(source))
        wait_for(lambda s: s["location"] == "fixtures", 15, sample)
        before = {op["id"] for op in status()["operations"]}
        hook("select:transfer")
        hook("command:copy")
        hook("go:" + str(target))
        wait_for(lambda s: s["location"] == "target", 15, sample)
        hook("command:paste")
        transfer_events = {}
        cancelled, request_sent = latest_operation(
            before, 300, sample, cancel_at=0.05, pause_at=0.02, events=transfer_events)
        record("transfer pause/resume", "paused then resumed before cancellation",
               transfer_events, transfer_events.get("paused") and transfer_events.get("resumed"))
        record("transfer cancellation", "cancelled after progress; no partial",
               {"operation": cancelled, "cancelSent": request_sent, "partials": partials(target)},
               request_sent and cancelled["state"] == "cancelled" and not partials(target))

        # A fresh target is made only after the prior operation is terminal.
        candidate = target / "transfer"
        if candidate.exists():
            shutil.rmtree(candidate)
        started = time.monotonic()
        hook("go:" + str(source))
        wait_for(lambda s: s["location"] == "fixtures", 15, sample)
        before = {op["id"] for op in status()["operations"]}
        hook("select:transfer")
        hook("command:copy")
        hook("go:" + str(target))
        wait_for(lambda s: s["location"] == "target", 15, sample)
        hook("command:paste")
        copied, _ = latest_operation(before, 1200, sample)
        copy_seconds = time.monotonic() - started
        copied_root = target / "transfer"
        verified = copied["state"] == "done" and copied_root.exists()
        if verified:
            verified = len(list((copied_root / "small").iterdir())) == 10_000
            verified = verified and hash_small_tree(copied_root / "small") == manifest["transfer_small_tree_sha256"]
            for name, expected in manifest["transfer_large_sha256"].items():
                verified = verified and hash_file(copied_root / name) == expected
        record("cross-volume copy", "10k files and 4 GiB match manifest",
               {"operation": copied, "seconds": copy_seconds, "verified": verified},
               verified, copy_seconds)

        moved_folder = target / "moved"
        moved_folder.mkdir(exist_ok=True)
        hook("go:" + str(source / "transfer"))
        wait_for(lambda s: s["location"] == "transfer" and s["itemsShown"] == 5, 15, sample)
        small_info = (source / "transfer/small").lstat()
        before = {op["id"] for op in status()["operations"]}
        hook("select:small")
        hook("command:cut")
        hook("go:" + str(moved_folder))
        wait_for(lambda s: s["location"] == "moved", 15, sample)
        hook("command:paste")
        moved, _ = latest_operation(before, 300, sample)
        moved_tree = moved_folder / "small"
        moved_ok = (moved["state"] == "done" and not (source / "transfer/small").exists()
                    and moved_tree.exists() and len(list(moved_tree.iterdir())) == 10_000
                    and hash_small_tree(moved_tree) == manifest["transfer_small_tree_sha256"])
        record("cross-volume move", "10k files verified and source retired", moved, moved_ok)
        cleaned_source = stress_image.remove_owned_trash_item(
            volumes[stress_image.SOURCE_NAME], (small_info.st_dev, small_info.st_ino))
        record("retired source cleanup", "only the verified retired source removed",
               {"inode": small_info.st_ino, "removed": cleaned_source}, cleaned_source)

        before = {op["id"] for op in status()["operations"]}
        hook("select:small")
        hook("command:trash")
        trashed, _ = latest_operation(before, 120, sample)
        record("image Trash", "only selected image tree moved to Trash", trashed,
               trashed["state"] == "done" and not moved_tree.exists())
        before = {op["id"] for op in status()["operations"]}
        hook("undo")
        restored, _ = latest_operation(before, 120, sample)
        record("Trash put-back", "tree restored with 10k items", restored,
               restored["state"] == "done" and moved_tree.exists()
               and len(list(moved_tree.iterdir())) == 10_000)
        record("no partials", "none on either image volume",
               {"source": partials(source), "target": partials(target)},
               not partials(source) and not partials(target))
    except Exception as error:
        results.append({"case": "runner", "expected": "all automated cases pass",
                        "observed": str(error), "passed": False})
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                results.append({"case": "app shutdown", "expected": "quit within 10s",
                                "observed": "still running", "passed": False})
        log_lines = []
        try:
            log = subprocess.check_output(
                ["/usr/bin/log", "show", "--last", "45m", "--style", "compact", "--predicate",
                 'subsystem == "com.antonispanos.scope" && (category == "StressOperations" || category == "StressPhases" || category == "StressLaunch")'],
                timeout=90, stderr=subprocess.DEVNULL).decode(errors="replace")
            log_lines = [line for line in log.splitlines() if run_id in line]
            (folder / "unified.log").write_text("\n".join(log_lines) + "\n")
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
        failed = [case for case in results if not case["passed"]]
        if failed:
            operations = last_snapshot["operations"] if last_snapshot else []
            last_operation = operations[-1] if operations else None
            phase_events = [line for line in log_lines if "phase=" in line]
            for case in failed:
                case["operation"] = last_operation
                case["phaseEvent"] = phase_events[-1] if phase_events else None
                case["relevantLogEvents"] = log_lines[-20:]
    report = {"runID": run_id, "repetition": index, "started": started_at,
              "image": str(stress_image.IMAGE), "sourceUUID": volumes[stress_image.SOURCE_NAME]["uuid"],
              "targetUUID": volumes[stress_image.TARGET_NAME]["uuid"], "cases": results,
              "passed": all(case["passed"] for case in results)}
    (folder / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"{run_id}: {'PASS' if report['passed'] else 'FAIL'} ({folder})", flush=True)
    return report


def aggregate():
    reports = [json.loads(path.read_text()) for path in RUNS.glob("*/result.json")]
    if not reports:
        raise RuntimeError("No stress runs found")
    recent = sorted(reports, key=lambda report: report["started"])[-3:]
    if len(recent) < 3 or not all(report["passed"] for report in recent):
        print("The latest three stress runs are not all passing")
        return 1
    metrics = {}
    for case_name in ("100k listing", "cross-volume copy"):
        values = [next(case["seconds"] for case in report["cases"] if case["case"] == case_name)
                  for report in recent]
        metrics[case_name] = statistics.median(values)
    throughputs = []
    peak_memory = []
    for report in recent:
        copied = next(case for case in report["cases"] if case["case"] == "cross-volume copy")
        throughputs.append(copied["observed"]["operation"]["bytesTotal"] / copied["seconds"] / (1024 ** 2))
        samples = RUNS / report["runID"] / "samples.jsonl"
        rss = [sample["rssKiB"] for sample in (json.loads(line) for line in samples.read_text().splitlines())
               if sample["rssKiB"] is not None]
        peak_memory.append(max(rss) / 1024 if rss else 0)
    metrics["throughputMiBps"] = statistics.median(throughputs)
    metrics["peakRSSMiB"] = statistics.median(peak_memory)
    baseline = BASE / "baseline.json"
    previous = json.loads(baseline.read_text()) if baseline.exists() else None
    regressions = {name: current / previous[name] for name, current in metrics.items()
                   if previous and name in previous and name != "throughputMiBps"
                   and current > 1.25 * previous[name]}
    if previous and "throughputMiBps" in previous and metrics["throughputMiBps"] < 0.75 * previous["throughputMiBps"]:
        regressions["throughputMiBps"] = metrics["throughputMiBps"] / previous["throughputMiBps"]
    if previous is None:
        baseline.write_text(json.dumps(metrics, indent=2) + "\n")
    elif any(name not in previous for name in metrics):
        baseline.write_text(json.dumps({**metrics, **previous}, indent=2) + "\n")
    print(json.dumps({"runs": [r["runID"] for r in recent], "medians": metrics,
                      "baseline": previous, "regressionsForReview": regressions}, indent=2))
    return 0


def low_space():
    global ACTIVE_RUN_ID
    stress_image.reset()
    stress_image.fill()
    volumes = stress_image.checked_volumes()
    source = stress_image.fixture_root(volumes[stress_image.SOURCE_NAME], "fixtures")
    target = stress_image.fixture_root(volumes[stress_image.TARGET_NAME], "target")
    manifest = json.loads(stress_image.MANIFEST.read_text())
    run_id = "low-space-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    ACTIVE_RUN_ID = run_id
    folder = LOW_SPACE_RUNS / run_id
    folder.mkdir(parents=True)
    results = []
    process = subprocess.Popen(
        [str(APP), "--scope-stress-image", str(stress_image.IMAGE),
         "--scope-stress-source", volumes[stress_image.SOURCE_NAME]["uuid"],
         "--scope-stress-target", volumes[stress_image.TARGET_NAME]["uuid"]],
        env=dict(os.environ, SCOPE_STRESS_RUN_ID=run_id),
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def sample(snapshot):
        with (folder / "samples.jsonl").open("a") as output:
            output.write(json.dumps({"time": time.time(), "status": snapshot,
                                     "rssKiB": rss_kib(process.pid),
                                     "targetFreeBytes": shutil.disk_usage(target).free}) + "\n")
    try:
        wait_for(lambda s: s["runID"] == run_id and s["location"] == stress_image.SOURCE_NAME,
                 20, sample)
        hook("go:" + str(source))
        wait_for(lambda s: s["location"] == "fixtures", 15, sample)
        before = {op["id"] for op in status()["operations"]}
        hook("select:transfer")
        hook("command:copy")
        hook("go:" + str(target))
        wait_for(lambda s: s["location"] == "target", 15, sample)
        hook("command:paste")
        operation, _ = latest_operation(before, 120, sample)
        intact = (source / "transfer").exists()
        if intact:
            intact = hash_small_tree(source / "transfer/small") == manifest["transfer_small_tree_sha256"]
            intact = intact and all(
                hash_file(source / "transfer" / name) == expected
                for name, expected in manifest["transfer_large_sha256"].items())
        passed = (operation["state"] == "failed" and operation["failure"]
                  and "free space" in operation["failure"].lower()
                  and intact and not (target / "transfer").exists() and not partials(target))
        results.append({"case": "low space copy", "passed": bool(passed),
                        "expected": "space failure with intact source and no published or partial target",
                        "observed": {"operation": operation, "sourceIntact": intact,
                                     "targetExists": (target / "transfer").exists(),
                                     "partials": partials(target)}})
    except Exception as error:
        results.append({"case": "low space copy", "passed": False,
                        "expected": "space failure with intact source and no published or partial target",
                        "observed": str(error)})
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
        try:
            log = subprocess.check_output(
                ["/usr/bin/log", "show", "--last", "15m", "--style", "compact", "--predicate",
                 'subsystem == "com.antonispanos.scope" && (category == "StressOperations" || category == "StressPhases")'],
                timeout=90, stderr=subprocess.DEVNULL).decode(errors="replace")
            (folder / "unified.log").write_text("\n".join(line for line in log.splitlines() if run_id in line) + "\n")
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
        stress_image.reset()
    report = {"runID": run_id, "cases": results, "passed": all(case["passed"] for case in results)}
    (folder / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"{run_id}: {'PASS' if report['passed'] else 'FAIL'} ({folder})", flush=True)
    return 0 if report["passed"] else 1


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "report":
        return aggregate()
    if len(sys.argv) != 2 or sys.argv[1] not in ("run", "low-space"):
        raise RuntimeError("usage: stress_run.py run|low-space|report")
    if not APP.exists() or not HOOK.exists() or not STATUS.exists():
        raise RuntimeError("Build Scope Dev, devhook, and stress_status first")
    if sys.argv[1] == "low-space":
        return low_space()
    RUNS.mkdir(parents=True, exist_ok=True)
    repetitions = int(os.environ.get("SCOPE_STRESS_REPETITIONS", "3"))
    if repetitions < 1 or repetitions > 3:
        raise RuntimeError("SCOPE_STRESS_REPETITIONS must be between 1 and 3")
    outcomes = [run_once(index + 1) for index in range(repetitions)]
    return 0 if all(report["passed"] for report in outcomes) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"stress run: {error}")
