#!/usr/bin/env python3
"""Replay existing telemetry only; certify the narrow 1x guard fallback claim.

This verifier neither starts a game nor changes the original acceptance report.
It does not establish uniform 2x gameplay, movement, or ordinary 2x acceptance.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import sys


MAX_BYTES = 8 * 1024 * 1024
TICKS = 10_000_000
PRODUCT = "AzerothSurvivorsSpeedGear"
GAME_SHA256 = "5dd6819d836748ccf809ab76fe6509c9ee793e087939b5d036c430d835a14e63"
SHA = re.compile(r"[0-9a-f]{40}\Z")
RUN_ID = re.compile(r"[1-9][0-9]{0,19}\Z")


class VerificationError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def number(value, name):
    require(type(value) in (int, float) and math.isfinite(value),
            f"invalid numeric field: {name}")
    return value


def integer(value, name):
    require(type(value) is int, f"invalid integer field: {name}")
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def finite_tree(value):
    if isinstance(value, dict):
        for child in value.values():
            finite_tree(child)
    elif isinstance(value, list):
        for child in value:
            finite_tree(child)
    elif type(value) is float:
        require(math.isfinite(value), "nonfinite JSON number")


def reject_constant(value):
    raise VerificationError(f"nonfinite JSON constant: {value}")


def load_report(path):
    with Path(path).open("rb") as stream:
        data = stream.read(MAX_BYTES + 1)
    require(len(data) <= MAX_BYTES, "trace exceeds 8 MiB")
    try:
        report = json.loads(data.decode("utf-8-sig"), object_pairs_hook=unique_object,
                            parse_constant=reject_constant)
        finite_tree(report)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise VerificationError("invalid bounded JSON trace") from error
    require(isinstance(report, dict), "trace root must be an object")
    return report, hashlib.sha256(data).hexdigest()


def verify_report(report, runtime_source_sha, verifier_source_sha, trace_run_id,
                  workflow_repository):
    """Recompute proof from raw samples; never trust criteria or metrics."""
    require(bool(SHA.fullmatch(runtime_source_sha)), "invalid runtime source SHA")
    require(bool(SHA.fullmatch(verifier_source_sha)), "invalid verifier source SHA")
    require(bool(RUN_ID.fullmatch(trace_run_id)), "invalid trace run ID")
    require(report.get("schema") == 1 and type(report.get("schema")) is int,
            "unsupported trace schema")
    require(report.get("product") == PRODUCT, "wrong trace product")
    require(report.get("sourceCommit") == runtime_source_sha, "runtime source mismatch")
    require(report.get("ciRunId") == trace_run_id, "trace run provenance mismatch")
    require(report.get("workflowRepository") == workflow_repository,
            "trace repository provenance mismatch")
    require(report.get("gameVersion") == "0.131.0", "unverified game version")
    require(report.get("gameSha256") == GAME_SHA256, "unverified game SHA256")
    require(report.get("pluginVersion") == "0.6.3", "unverified plugin version")
    require(report.get("acceptanceMode") == "frame_guard_fallback", "wrong acceptance mode")
    runs = report.get("runs")
    require(isinstance(runs, list) and len(runs) == 2, "expected baseline and hooked runs")
    require(isinstance(runs[0], dict) and runs[0].get("mode") == "baseline",
            "missing baseline identity")
    hooked = runs[1]
    require(isinstance(hooked, dict) and hooked.get("mode") == "hooked",
            "missing hooked run")
    rows = hooked.get("samples")
    require(isinstance(rows, list) and rows, "missing raw hooked samples")
    previous_time = previous_seq = -1
    for row in rows:
        require(isinstance(row, dict), "invalid sample object")
        timestamp = integer(row.get("fileTime"), "fileTime")
        sequence = integer(row.get("seq"), "seq")
        require(timestamp > previous_time and sequence > previous_seq,
                "samples must have increasing wall time and sequence")
        previous_time, previous_seq = timestamp, sequence
    stage_three = [row for row in rows if row.get("stage") == 3]
    require(stage_three, "missing stage 3")
    guards = [row for row in stage_three if row.get("mode") == 1
              and row.get("target") == 200 and row.get("phase") == "playing"
              and row.get("guardTripped") is True and row.get("effectiveSpeed100") == 100]
    require(guards, "missing actual playing 2x-target guard fallback")
    guard = guards[0]
    require(hooked.get("firstGuardRow") == guard, "first guard summary does not match raw evidence")
    guard_time = guard["fileTime"]

    snapshot = hooked.get("postGuardNative")
    require(isinstance(snapshot, dict), "missing later native snapshot")
    native_time = integer(snapshot.get("fileTime"), "native fileTime")
    native_delay = (native_time - guard_time) / TICKS
    require(native_delay >= 1.5, "native snapshot is too early")
    require(native_time <= rows[-1]["fileTime"], "native snapshot is outside the observed run")
    reported_delay = number(snapshot.get("secondsAfterGuard"), "secondsAfterGuard")
    require(abs(reported_delay - native_delay) <= 0.000001,
            "native snapshot delay disagrees with external wall time")
    native = snapshot.get("nativeBackend")
    require(isinstance(native, dict), "missing native backend status")
    require(native.get("statusAvailable") is True and native.get("backend") == "ready",
            "native backend is not ready")
    require(native.get("transport") in ("console", "file"), "invalid native transport")
    require(type(native.get("speed100")) is int and native["speed100"] == 100,
            "native backend did not restore 1x")
    heartbeat = number(native.get("heartbeatAgeMs"), "heartbeatAgeMs")
    require(0 <= heartbeat <= 8000, "native heartbeat is stale")
    log = native.get("safeLog")
    require(isinstance(log, list) and all(isinstance(line, str) for line in log),
            "missing normalized native log")
    transitions = []
    for line in log:
        match = re.fullmatch(r"speed100=(100|200) simulation_calls=([0-9]+)",
                             " ".join(line.split()))
        if match:
            transitions.append((int(match[1]), int(match[2])))
    activated = restored = None
    for speed, calls in transitions:
        if activated is None and speed == 200:
            activated = calls
        elif activated is not None and restored is None and speed == 100 and calls > activated:
            restored = calls
        elif restored is not None:
            require(speed == 100 and calls >= restored, "native log accelerates again after restore")
    require(activated is not None and restored is not None,
            "native log lacks ordered active 2x then restored 1x with increasing calls")

    later = [row for row in rows if row["fileTime"] > guard_time
             and row.get("target") == 200 and row.get("stage") in (3, 4)]
    require(len(later) >= 2 and any(row.get("stage") == 4 for row in later),
            "missing later stage 4 accelerated-target latch evidence")
    require(all(row.get("guardTripped") is True and row.get("effectiveSpeed100") == 100
                for row in later), "guard latch permitted a later accelerated-target burst")
    latch_span = (later[-1]["fileTime"] - guard_time) / TICKS
    require(latch_span >= 5, "guard latch evidence is shorter than five seconds")

    cutoff = max(stage_three[0]["fileTime"] + 2 * TICKS, guard_time + 15_000_000)
    window = [row for row in stage_three if row["fileTime"] >= cutoff]
    require(len(window) >= 8, "insufficient post-guard samples")
    require(all(row.get("phase") == "playing" and row.get("target") == 200
                and row.get("mode") == 1 for row in window), "post-guard window is not actual playing")
    span = (window[-1]["fileTime"] - window[0]["fileTime"]) / TICKS
    require(span >= 5, "post-guard window is shorter than five seconds")
    gaps = [(b["fileTime"] - a["fileTime"]) / TICKS for a, b in zip(window, window[1:])]
    require(max(gaps) <= 1, "post-guard samples are not continuous")
    for row in window:
        for field in ("rawT", "spellId", "cd", "cdmax", "spellPackets", "selfDamageEvents"):
            number(row.get(field), field)
        require(row["rawT"] >= 0 and row["spellId"] > 0 and row["cdmax"] > 0
                and 0 <= row["cd"] <= row["cdmax"], "invalid post-guard raw gameplay fields")
    require(all(b["rawT"] >= a["rawT"] and b["spellPackets"] >= a["spellPackets"]
                and b["selfDamageEvents"] >= a["selfDamageEvents"]
                for a, b in zip(window, window[1:])), "raw progress counters regress")
    raw_rate = (window[-1]["rawT"] - window[0]["rawT"]) / span
    require(0.75 <= raw_rate <= 1.25, "post-guard raw time is outside absolute 1x bounds")
    require(all(row["spellId"] == window[0]["spellId"]
                and row["cdmax"] == window[0]["cdmax"] for row in window),
            "spell identity or cooldown maximum changes")
    previous_packet = window[0]
    decay = decay_span = 0.0
    decay_intervals = 0
    for row in window[1:]:
        if row["spellPackets"] > previous_packet["spellPackets"]:
            # Keep the denominator across repeated UI rows of the same packet.
            elapsed = (row["fileTime"] - previous_packet["fileTime"]) / TICKS
            if previous_packet["cd"] > row["cd"]:
                decay += previous_packet["cd"] - row["cd"]
                decay_span += elapsed
                decay_intervals += 1
            previous_packet = row
    require(decay_span >= 1, "insufficient distinct-packet cooldown decay")
    cooldown_rate = decay / decay_span
    require(0.7 <= cooldown_rate <= 1.3, "post-guard cooldown is outside absolute 1x bounds")
    damage = window[-1]["selfDamageEvents"] - window[0]["selfDamageEvents"]
    require(damage > 0, "missing actual positive self-damage event progress")
    return {
        "firstGuardFileTime": guard_time, "firstGuardSequence": guard["seq"],
        "nativeSecondsAfterGuard": native_delay, "nativeHeartbeatAgeMs": heartbeat,
        "nativeActivatedSimulationCalls": activated, "nativeRestoredSimulationCalls": restored,
        "postGuardSampleCount": len(window), "postGuardExternalSeconds": span,
        "postGuardMaxSampleGapSeconds": max(gaps), "postGuardRawTimeRate": raw_rate,
        "postGuardCooldownDecayRate": cooldown_rate, "cooldownDecay": decay,
        "cooldownDecayExternalSeconds": decay_span, "cooldownDecayIntervals": decay_intervals,
        "selfDamageEvents": damage, "latchedTargetSampleCount": len(later),
        "latchedStageFourSampleCount": sum(row["stage"] == 4 for row in later),
        "latchedExternalSeconds": latch_span,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--runtime-source-sha", required=True)
    parser.add_argument("--verifier-source-sha", required=True)
    parser.add_argument("--trace-run-id", required=True)
    parser.add_argument("--workflow-repository", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    verdict = {
        "schema": 1, "type": "frame_guard_fallback_only", "status": "failed",
        "claim": "An activated 2x target tripped the frame guard, restored native 1x, and remained latched.",
        "scope": "Existing remote trace replay only; no uniform 2x gameplay or movement certification.",
        "runtimeSourceSHA": args.runtime_source_sha, "verifierSourceSHA": args.verifier_source_sha,
        "sourceGitHubRunId": args.trace_run_id, "workflowRepository": args.workflow_repository,
        "verifierFileSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    try:
        report, digest = load_report(args.report)
        verdict.update({"sourceReportSHA256": digest, "originalRunStatus": report.get("status"),
                        "originalMissingEvidence": report.get("missingEvidence"),
                        "originalRunNotes": {"reason": report.get("reason"),
                                             "missingEvidence": report.get("missingEvidence"),
                                             "scope": report.get("scope")}})
        verdict["proof"] = verify_report(report, args.runtime_source_sha, args.verifier_source_sha,
                                         args.trace_run_id, args.workflow_repository)
        verdict["status"] = "passed"
    except (VerificationError, OSError, ValueError, TypeError, OverflowError) as error:
        verdict["error"] = str(error)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(verdict, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    print(json.dumps({"status": verdict["status"], "type": verdict["type"]}))
    return 0 if verdict["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
