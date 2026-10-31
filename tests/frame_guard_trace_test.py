"""Synthetic trace replay tests; intended to execute in remote CI only."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("guard_trace", ROOT / "tools/verify_frame_guard_trace.py")
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)
SOURCE = "51e089f2d74b3c971c75b5a6cde15e2e2e5145e7"
VERIFIER_SOURCE = "a" * 40
RUN = "41175749484"
REPOSITORY = "fubukisama/AzerothSurvivorsSpeedGear"


def fixture():
    # rawT and cooldown values originate independently from the wall timestamps.
    rows = []
    for index in range(24):
        packet = (index + 1) // 2
        rows.append({"fileTime": 134379011000000000 + index * 5_000_000,
                     "seq": index + 1, "mode": 1, "target": 200,
                     "stage": 3 if index < 20 else 4, "phase": "playing",
                     "rawT": 20 + index / 2, "spellId": 845,
                     "cd": [4, 3, 2, 1][packet % 4], "cdmax": 4,
                     "spellPackets": 100 + packet, "selfDamageEvents": packet,
                     "guardTripped": index >= 2, "effectiveSpeed100": 100 if index >= 2 else 200})
    return {"schema": 1, "product": verifier.PRODUCT, "status": "blocked",
            "reason": "original_baseline_cadence", "missingEvidence": ["unhooked.continuousSamples"],
            "sourceCommit": SOURCE, "ciRunId": RUN, "workflowRepository": REPOSITORY,
            "gameVersion": "0.131.0", "gameSha256": verifier.GAME_SHA256,
            "pluginVersion": "0.6.3", "acceptanceMode": "frame_guard_fallback",
            "criteria": [{"passed": False}], "metrics": {"rawRunRate": 99},
            "runs": [{"mode": "baseline", "samples": []},
                     {"mode": "hooked", "samples": rows, "firstGuardRow": copy.deepcopy(rows[2]),
                      "postGuardNative": {"fileTime": rows[2]["fileTime"] + 15_000_000,
                                          "secondsAfterGuard": 1.5,
                                          "nativeBackend": {"statusAvailable": True, "backend": "ready",
                                                            "transport": "console", "speed100": 100,
                                                            "heartbeatAgeMs": 296,
                                                            "safeLog": ["speed100=200 simulation_calls=2523",
                                                                        " speed100=100  simulation_calls=2578 "]}}}]}


class GuardTraceTests(unittest.TestCase):
    def verify(self, report):
        return verifier.verify_report(report, SOURCE, VERIFIER_SOURCE, RUN, REPOSITORY)

    def rejected(self, mutate):
        report = fixture()
        mutate(report)
        report["runs"][1]["firstGuardRow"] = copy.deepcopy(report["runs"][1]["samples"][2])
        with self.assertRaises(verifier.VerificationError):
            self.verify(report)

    def test_valid_raw_evidence_ignores_original_criteria_and_baseline_cadence(self):
        report = fixture()
        before = copy.deepcopy(report)
        proof = self.verify(report)
        self.assertEqual(proof["postGuardRawTimeRate"], 1)
        self.assertEqual(proof["postGuardCooldownDecayRate"], 1)
        self.assertGreater(proof["selfDamageEvents"], 0)
        self.assertEqual(report, before)

    def test_native_still_200(self):
        self.rejected(lambda r: r["runs"][1]["postGuardNative"]["nativeBackend"].update(speed100=200))

    def test_guard_missing(self):
        self.rejected(lambda r: [row.update(guardTripped=False) for row in r["runs"][1]["samples"]])

    def test_latched_burst(self):
        self.rejected(lambda r: r["runs"][1]["samples"][-1].update(effectiveSpeed100=200))

    def test_post_guard_raw_rate_2(self):
        self.rejected(lambda r: [row.update(rawT=40 + index) for index, row
                                 in enumerate(r["runs"][1]["samples"])])

    def test_missing_stage_four(self):
        self.rejected(lambda r: [row.update(stage=3) for row in r["runs"][1]["samples"]])

    def test_cooldown_rate_2(self):
        self.rejected(lambda r: [row.update(cd=row["cd"] * 2, cdmax=row["cdmax"] * 2)
                                 for row in r["runs"][1]["samples"]])

    def test_insufficient_post_guard_cadence(self):
        self.rejected(lambda r: r["runs"][1].update(
            samples=[row for index, row in enumerate(r["runs"][1]["samples"])
                     if index not in (8, 9)]))

    def test_wrong_source(self):
        self.rejected(lambda r: r.update(sourceCommit="b" * 40))

    def test_no_native_transition(self):
        self.rejected(lambda r: r["runs"][1]["postGuardNative"]["nativeBackend"].update(
            safeLog=["speed100=100 simulation_calls=2578"]))

    def test_reversed_native_transition(self):
        self.rejected(lambda r: r["runs"][1]["postGuardNative"]["nativeBackend"].update(
            safeLog=["speed100=100 simulation_calls=2578", "speed100=200 simulation_calls=2523"]))

    def test_stale_native_heartbeat(self):
        self.rejected(lambda r: r["runs"][1]["postGuardNative"]["nativeBackend"].update(heartbeatAgeMs=8001))

    def test_no_damage_progress(self):
        self.rejected(lambda r: [row.update(selfDamageEvents=3) for row in r["runs"][1]["samples"]])

    def test_duplicate_keys_and_nonfinite_rejected(self):
        for content in (b'{"schema":1,"schema":1}', b'{"x":NaN}', b'{"x":1e999}'):
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "report.json"
                path.write_bytes(content)
                with self.assertRaises(verifier.VerificationError):
                    verifier.load_report(path)

    def test_oversized_json_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_bytes(b" " * (verifier.MAX_BYTES + 1))
            with self.assertRaises(verifier.VerificationError):
                verifier.load_report(path)


if __name__ == "__main__":
    unittest.main()
