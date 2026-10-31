import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("verify_hotkey_trace", ROOT / "tools" / "verify_hotkey_trace.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class HotkeyTraceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = json.loads((ROOT / "docs/evidence/hotkeys0131raw.json").read_text(encoding="utf-8-sig"))

    def rejects(self, change):
        report = copy.deepcopy(self.report)
        change(report)
        with self.assertRaises(MODULE.EvidenceError):
            MODULE.verify(report, "a" * 64)

    def test_real_trace_preserves_original_failure(self):
        verdict = MODULE.verify(copy.deepcopy(self.report), "a" * 64)
        self.assertEqual(verdict["status"], "passed")
        self.assertEqual(verdict["originalRun"]["status"], "failed")
        self.assertFalse(verdict["finalSessionGracefulExit"])

    def test_wrong_source(self):
        self.rejects(lambda r: r.update(sourceCommit="0" * 40))

    def test_missing_physical_key(self):
        self.rejects(lambda r: r["hotkeys"]["sessions"][0].update(inputs=[i for i in r["hotkeys"]["sessions"][0]["inputs"] if i.get("vk") != 81]))

    def test_stale_native_receipt(self):
        def change(report):
            for collection in (report["criteria"], report["hotkeys"]["criteria"]):
                next(c for c in collection if c["name"] == "q_slower_native")["observed"]["observation"]["fileTime"] = 1
        self.rejects(change)

    def test_wrong_recorded_key(self):
        def change(report):
            for collection in (report["criteria"], report["hotkeys"]["criteria"]):
                next(c for c in collection if c["name"] == "record_down_r")["observed"]["captureKey"] = "T"
        self.rejects(change)

    def test_saved_check_false(self):
        def change(report):
            for collection in (report["criteria"], report["hotkeys"]["criteria"]):
                next(c for c in collection if c["name"] == "saved_custom_keys")["observed"] = False
        self.rejects(change)

    def test_reload_missing(self):
        self.rejects(lambda r: r["hotkeys"]["sessions"].pop())

    def test_other_failure_not_allowed(self):
        def change(report):
            for collection in (report["criteria"], report["hotkeys"]["criteria"]):
                next(c for c in collection if c["name"] == "r_slower_dispatch")["passed"] = False
        self.rejects(change)

    def test_ctrl_not_held(self):
        self.rejects(lambda r: r["hotkeys"]["sessions"][2].update(inputs=[i for i in r["hotkeys"]["sessions"][2]["inputs"] if i.get("vk") != 17]))

    def test_duplicate_json_keys(self):
        with self.assertRaises(MODULE.EvidenceError):
            json.loads('{"x":1,"x":2}', object_pairs_hook=MODULE.unique_pairs)


if __name__ == "__main__":
    unittest.main()
