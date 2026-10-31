"""Recheck the pinned real-game hotkey trace; preserve its cleanup failure."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

SOURCE = "66967a64091c03176bd12f9f24d43637d1d55b6b"
GAME_SHA = "5dd6819d836748ccf809ab76fe6509c9ee793e087939b5d036c430d835a14e63"
RUN = "41183605168"
FAILURE = "failed_session3_graceful_exit"
LIMIT = 8 * 1024 * 1024


class EvidenceError(ValueError):
    pass


def need(condition, name):
    if not condition:
        raise EvidenceError(name)


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise EvidenceError("duplicate_json_key")
        result[key] = value
    return result


def verify(report, raw_sha256):
    need(isinstance(report, dict), "report_object")
    need(report.get("schema") == 1 and report.get("product") == "AzerothSurvivorsSpeedGear", "product")
    need(report.get("sourceCommit") == SOURCE and str(report.get("ciRunId")) == RUN, "source_identity")
    need(report.get("gameVersion") == "0.131.0" and report.get("gameSha256") == GAME_SHA
         and report.get("gameBytes") == 147231744 and report.get("pluginVersion") == "0.7.1", "game_identity")
    need(re.fullmatch(r"[a-f0-9]{64}", report.get("candidateDllSha256", "")) is not None, "dll_identity")
    need(report.get("status") == "failed" and report.get("reason") == FAILURE, "original_failure_preserved")
    hotkeys = report.get("hotkeys", {})
    need(hotkeys.get("status") == "failed" and hotkeys.get("reason") == FAILURE, "nested_original_failure")
    criteria = report.get("criteria")
    need(isinstance(criteria, list) and len(criteria) == 51 and criteria == hotkeys.get("criteria"), "criteria_identity")
    need(all(isinstance(c, dict) and type(c.get("passed")) is bool for c in criteria), "criterion_booleans")
    failed = [c for c in criteria if not c["passed"]]
    need(len(failed) == 1 and failed[0].get("name") == "session3_graceful_exit"
         and failed[0].get("observed") is False, "only_terminal_cleanup_may_fail")
    sessions = hotkeys.get("sessions")
    need(isinstance(sessions, list) and len(sessions) == 3, "three_sessions")
    for number, session in enumerate(sessions, 1):
        need(session.get("number") == number and session.get("softwareAdapterObserved") is True
             and session.get("panicked") is False and session.get("gpuFailure") is False
             and session.get("droppedTelemetry") == 0, "healthy_session")
        need(session.get("gracefulExit") is (number != 3), "session_exit_record")
        need(isinstance(session.get("samples"), list) and 1 <= len(session["samples"]) <= 2500, "raw_samples")
        need(isinstance(session.get("inputs"), list) and 1 <= len(session["inputs"]) <= 500, "raw_inputs")
        need(all(i.get("sent") is True and type(i.get("fileTime")) is int for i in session["inputs"]), "physical_input_delivery")

    def criterion(name):
        values = [c for c in criteria if c.get("name") == name]
        need(len(values) == 1 and values[0]["passed"] is True, "criterion_" + name)
        return values[0].get("observed")

    def row(name, session):
        observed = criterion(name)
        need(observed in session["samples"], "raw_row_" + name)
        return observed

    def press(session, vk, after=0, modifier=False):
        downs = [i for i in session["inputs"] if i.get("kind") == "keyboard" and i.get("vk") == vk
                 and i.get("down") is True and i["fileTime"] > after]
        need(bool(downs), "physical_key_down")
        down = downs[0]
        ups = [i for i in session["inputs"] if i.get("kind") == "keyboard" and i.get("vk") == vk
               and i.get("down") is False and i["fileTime"] > down["fileTime"]]
        need(bool(ups) and ups[0]["fileTime"] - down["fileTime"] <= 100000000, "physical_key_up")
        if modifier:
            controls = [i for i in session["inputs"] if i.get("kind") == "keyboard" and i.get("vk") == 17
                        and i.get("down") is True and after < i["fileTime"] < down["fileTime"]]
            need(bool(controls), "physical_ctrl_down")
            ctrl = controls[-1]
            releases = [i for i in session["inputs"] if i.get("kind") == "keyboard" and i.get("vk") == 17
                        and i.get("down") is False and i["fileTime"] > ctrl["fileTime"]]
            need(bool(releases) and releases[0]["fileTime"] >= ups[0]["fileTime"], "physical_ctrl_held_through_t")
        return down, ups[0]

    def click(session, button, observed):
        values = [i for i in session["inputs"] if i.get("kind") == "mouse" and i.get("button") == button
                  and i["fileTime"] <= observed["fileTime"]]
        need(bool(values), "physical_panel_click")
        value = values[-1]
        need(type(value.get("downFileTime")) is int and value["downFileTime"] < value["fileTime"]
             and 0 < value.get("holdMilliseconds", 0) <= 6500
             and value.get("releaseFrame", 0) >= value.get("firstFrame", 0) + 2, "mouse_hold_observed")
        need(any(i.get("kind") == "mouse_move" and i.get("button") == button
                 and i["fileTime"] < value["downFileTime"] for i in session["inputs"]), "physical_hover")

    def action(session, prefix, vk, count, before, target, direction, after=0, modifier=False):
        down, up = press(session, vk, after, modifier)
        observed = row(prefix + "_dispatch", session)
        need(observed.get("fileTime", 0) >= down["fileTime"] and observed.get("actions") == count
             and observed.get("direction") == direction and observed.get("before") == before
             and observed.get("after") == target and observed.get("accepted") == 1
             and observed.get("phase") == "playing" and observed.get("active") == 1
             and observed.get("panel") == 0 and observed.get("capture") == 0, "raw_hotkey_action")
        receipt = criterion(prefix + "_native")
        need(isinstance(receipt, dict), "native_receipt_object")
        observation = receipt.get("observation", {})
        need(type(receipt.get("actionStarted")) is int
             and receipt["actionStarted"] <= down["fileTime"] <= observation.get("fileTime", 0)
             and observation.get("backend") == "ready" and observation.get("speed100") == target, "fresh_native_receipt")
        if receipt.get("source") == "status":
            need(observation in session.get("nativeTransitions", []), "raw_native_status")
        else:
            need(target == 200 and receipt.get("source") == "change_log"
                 and observation in session.get("nativeLogEvents", []), "raw_native_change_log")
            need(type(observation.get("simulationCalls")) is int and observation["simulationCalls"] > 0
                 and observation.get("message") == "speed100=200 simulation_calls=" + str(observation["simulationCalls"]), "native_change_identity")
            need(not any(e.get("message") == observation["message"] and e.get("fileTime", 0) < receipt["actionStarted"]
                         for e in session.get("nativeLogEvents", [])), "native_change_not_stale")
        return up["fileTime"]

    first, configured, reloaded = sessions
    initial = row("default_qe_bindings", first)
    need((initial.get("down"), initial.get("up"), initial.get("q"), initial.get("e"))
         == ("Q", "E", "AZSG_SLOWER", "AZSG_FASTER"), "default_keys")
    last = action(first, "q_slower", 81, 1, 100, 50, -1)
    last = action(first, "e_faster", 69, 2, 50, 100, 1, last)
    action(first, "e_accelerated", 69, 3, 100, 200, 1, last)
    need(criterion("session1_graceful_exit") is True, "first_clean_exit")
    ready = row("session2_ready", configured)
    need(ready.get("phase") == "ready" and ready.get("active") == 0 and ready.get("rawT") == 0, "real_ready_configuration")
    down_open = row("record_down_opened", configured)
    up_open = row("record_up_opened", configured)
    for name, observed in (("downButton", down_open), ("upButton", up_open)):
        need(observed.get("capture") == 1 and observed.get("panel") == 1 and observed.get("phase") == "ready", "real_recorder")
        click(configured, name, observed)
    recorded_r = row("record_down_r", configured)
    recorded_t = row("record_up_ctrl_t", configured)
    r_press, r_up = press(configured, 82, down_open["fileTime"])
    t_press, _ = press(configured, 84, up_open["fileTime"], True)
    need(recorded_r.get("captureKey") == "R" and recorded_r.get("down") == "R"
         and recorded_r.get("r") == "AZSG_SLOWER" and recorded_r.get("fileTime", 0) >= r_press["fileTime"], "recorded_r")
    need(recorded_t.get("captureKey") == "T" and recorded_t.get("up") == "CTRL-T"
         and recorded_t.get("ctrlT") == "AZSG_FASTER" and recorded_t.get("fileTime", 0) >= t_press["fileTime"]
         and recorded_t.get("capture") == 0 and recorded_t.get("actions") == 0, "recorded_ctrl_t")
    need(any(r.get("captureKey") == "CTRL" and r.get("captureEvents") == recorded_t.get("captureEvents", 0) - 1
             and up_open["fileTime"] <= r.get("fileTime", 0) <= recorded_t["fileTime"] for r in configured["samples"]), "captured_ctrl_event")
    need(recorded_t.get("q") == recorded_t.get("originalQ") == "STRAFELEFT"
         and recorded_t.get("e") == recorded_t.get("originalE") == "STRAFERIGHT", "original_game_bindings_restored")
    criterion("old_q_binding_restored"); criterion("old_e_binding_restored")
    last = action(configured, "r_slower", 82, 1, 100, 50, -1, r_up["fileTime"])
    action(configured, "ctrl_t_faster", 84, 2, 50, 100, 1, last, True)
    need(criterion("session2_graceful_exit") is True and criterion("saved_custom_keys") is True, "saved_after_clean_exit")
    loaded = row("reloaded_custom_bindings", reloaded)
    need(loaded.get("phase") == "ready" and loaded.get("rawT") == 0
         and (loaded.get("down"), loaded.get("up"), loaded.get("r"), loaded.get("ctrlT"))
         == ("R", "CTRL-T", "AZSG_SLOWER", "AZSG_FASTER")
         and loaded.get("instance") != ready.get("instance")
         and loaded["fileTime"] > configured["samples"][-1]["fileTime"], "fresh_process_saved_bindings")
    last = action(reloaded, "reloaded_r_slower", 82, 1, 100, 50, -1)
    action(reloaded, "reloaded_ctrl_t_faster", 84, 2, 50, 100, 1, last, True)
    return {
        "schema": 1, "product": "AzerothSurvivorsSpeedGear", "status": "passed",
        "acceptance": "physical_hotkeys_and_saved_restart_only", "sourceCommit": SOURCE,
        "gameVersion": "0.131.0", "gameSha256": GAME_SHA, "pluginVersion": "0.7.1",
        "sourceReportSHA256": raw_sha256, "ciRunId": RUN,
        "originalRun": {"status": report["status"], "reason": report["reason"], "passedCriteria": 50, "totalCriteria": 51},
        "verified": ["physical_default_q_e", "fresh_native_0.5_1_2", "physical_panel_r_ctrl_t_recording",
                     "original_q_e_restored", "hidden_panel_custom_keys", "clean_save_and_restart", "reloaded_physical_keys_and_native_speed"],
        "cleanupWarning": "The final third-session window did not exit within 30 seconds; the original workflow remains failed.",
        "finalSessionGracefulExit": False,
        "scope": "Numerical and physical-input functionality on one remote game build. Screenshots are not fresh visual acceptance. No uniform movement, skill timing, future-version or clean-final-shutdown certification.",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        need(args.report.stat().st_size <= LIMIT, "report_size")
        raw = args.report.read_bytes()
        report = json.loads(raw.decode("utf-8-sig"), object_pairs_hook=unique_pairs,
                            parse_constant=lambda value: (_ for _ in ()).throw(EvidenceError("nonfinite_json")))
        verdict = verify(report, hashlib.sha256(raw).hexdigest())
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(verdict, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(verdict, ensure_ascii=False, separators=(",", ":")))
        return 0
    except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError) as error:
        print(json.dumps({"status": "failed", "reason": str(error) if isinstance(error, EvidenceError) else "invalid_evidence"}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
