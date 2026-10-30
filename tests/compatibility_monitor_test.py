"""Offline mocks/fixtures for the remote-only official compatibility monitor."""
import gzip
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from urllib.error import URLError


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("azsg_compat_monitor", ROOT / "tools/check_game_compatibility.py")
monitor = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = monitor
SPEC.loader.exec_module(monitor)


def synthetic_pe(names=("DwmIsCompositionEnabled",), ordinals=(), dll="dwmapi.dll"):
    """An inert x64 PE import fixture; no fixture is executed."""
    data = bytearray(0x600)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", data, 0x84, 0x8664, 1)
    struct.pack_into("<H", data, 0x94, 240)
    optional = 0x98
    struct.pack_into("<H", data, optional, 0x20B)
    struct.pack_into("<Q", data, optional + 24, 0x140000000)
    struct.pack_into("<I", data, optional + 56, 0x2000)
    struct.pack_into("<I", data, optional + 60, 0x200)
    struct.pack_into("<I", data, optional + 108, 16)
    struct.pack_into("<II", data, optional + 120, 0x1000, 40)
    section = optional + 240
    struct.pack_into("<IIII", data, section + 8, 0x400, 0x1000, 0x400, 0x200)
    struct.pack_into("<IIIII", data, 0x200, 0x10A0, 0, 0, 0x1080, 0x10A0)
    raw_dll = dll.encode("ascii") + b"\0"
    data[0x280:0x280 + len(raw_dll)] = raw_dll
    values = []
    for index, name in enumerate(names):
        rva = 0x10C0 + index * 0x60
        raw = b"\0\0" + name.encode("ascii") + b"\0"
        offset = rva - 0x1000 + 0x200
        data[offset:offset + len(raw)] = raw
        values.append(rva)
    values += [(1 << 63) | ordinal for ordinal in ordinals]
    for index, value in enumerate(values + [0]):
        struct.pack_into("<Q", data, 0x2A0 + index * 8, value)
    return bytes(data)


class Response(io.BytesIO):
    def __init__(self, content, url):
        super().__init__(content)
        self.url = url

    def geturl(self):
        return self.url


class Network:
    def __init__(self, routes):
        self.routes = routes
        self.calls = []

    def open(self, request, timeout):
        url = request.full_url
        self.calls.append(url)
        if timeout <= 0:
            raise AssertionError("network requests must have a timeout")
        if url not in self.routes:
            raise URLError("offline mock")
        value = self.routes[url]
        if isinstance(value, Exception):
            raise value
        return Response(value, url)


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="AZSG-monitor-unit-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.output = self.directory / "windows.json"
        self.probe = self.directory / "AZSSpeedGearProbe.exe"
        self.probe.write_bytes(b"not executable; runner is mocked")
        self.definition = self.directory / "proxy.def"
        self.definition.write_text("LIBRARY dwmapi\nEXPORTS\n  DwmIsCompositionEnabled=forward_0 @104\n  forward_1=forward_1 @103 NONAME\n", encoding="utf-8")
        self.payload = synthetic_pe(ordinals=(103,))
        self.configure_network(self.payload)
        self.probe_paths = []

    def configure_network(self, payload):
        self.payload = payload
        compressed = gzip.compress(payload, mtime=0)
        split1, split2 = len(compressed) // 3, 2 * len(compressed) // 3
        chunks = [compressed[:split1], compressed[split1:split2], compressed[split2:]]
        self.manifest = {"version": "0.130.0", "notes": "fixture", "size": len(payload),
            "sha256": monitor.hashlib.sha256(payload).hexdigest(),
            "parts": [{"url": f"0.130.0/part-{index:03}.bin", "size": len(chunk)} for index, chunk in enumerate(chunks)]}
        self.routes = {monitor.MANIFEST_URL: json.dumps(self.manifest).encode()}
        for part, chunk in zip(self.manifest["parts"], chunks):
            self.routes[monitor.safe_url(part["url"], relative=True)] = chunk
        self.network = Network(self.routes)

    def sync_manifest(self):
        self.routes[monitor.MANIFEST_URL] = json.dumps(self.manifest).encode()

    def successful_probe(self, command, **kwargs):
        self.assertEqual(Path(command[0]), self.probe)
        self.assertEqual(command[2], "--selftest")
        self.assertEqual(Path(command[1]).read_bytes(), self.payload)
        self.assertGreater(kwargs["timeout"], 0)
        self.probe_paths.append(Path(command[1]))
        return subprocess.CompletedProcess(command, 0,
            "x64=1 image_size=8192 scan=fixture\nsleep_rva=0x100 return_rva=0x200 nanos=25000000\nscanner-negative-tests=passed\n", "")

    def check(self, **options):
        values = dict(probe=self.probe, output=self.output, definition=self.definition,
            fingerprint="a" * 64, commit="b" * 40, ci_run_id="12345", opener=self.network,
            runner=self.successful_probe)
        values.update(options)
        return monitor.monitor_once(**values)

    def test_split_gzip_integrity_loader_and_report(self):
        report, skipped = self.check()
        self.assertFalse(skipped)
        self.assertEqual(report["product"], monitor.PRODUCT)
        self.assertEqual(report["status"], "structural_only")
        self.assertEqual(report["gameSha256"], self.manifest["sha256"])
        self.assertEqual(report["gameBytes"], len(self.payload))
        self.assertNotIn("builds", report)
        self.assertNotIn("gameplay_verified", report.values())
        self.assertLessEqual(len(report["reason"]), 512)
        self.assertTrue(all(not path.exists() for path in self.probe_paths))
        self.assertEqual(json.loads(self.output.read_text()), report)
        self.assertEqual(len(self.network.calls), 4)

    def test_report_commit_changes_do_not_redownload(self):
        first, _ = self.check()
        self.network.calls.clear()
        second, skipped = self.check(commit="c" * 40, runner=mock.Mock(side_effect=AssertionError("must not run")))
        self.assertTrue(skipped)
        self.assertEqual(second, first)
        self.assertEqual(self.network.calls, [monitor.MANIFEST_URL])

    def test_engine_fingerprint_change_rechecks(self):
        self.check()
        self.network.calls.clear()
        _, skipped = self.check(fingerprint="d" * 64)
        self.assertFalse(skipped)
        self.assertEqual(len(self.network.calls), 4)

    def test_loader_requires_ordinary_dwm_import(self):
        self.configure_network(synthetic_pe(dll="user32.dll"))
        report, _ = self.check(runner=mock.Mock(side_effect=AssertionError("no loader, no probe")))
        self.assertEqual(report["status"], "unsupported")
        self.assertTrue(report["reason"].startswith("loader-no-dwmapi:"))

    def test_loader_rejects_new_named_or_ordinal_exports(self):
        for payload in (synthetic_pe(names=("DwmFutureFunction",)), synthetic_pe(ordinals=(999,))):
            with self.subTest(payload_sha=monitor.hashlib.sha256(payload).hexdigest()):
                self.configure_network(payload)
                report, _ = self.check()
                self.assertEqual(report["status"], "unsupported")
                self.assertTrue(report["reason"].startswith("loader-missing-exports:"))

    def test_loader_rejects_malformed_pe(self):
        self.configure_network(b"MZ invalid fixture")
        report, _ = self.check()
        self.assertEqual(report["status"], "unsupported")
        self.assertTrue(report["reason"].startswith("loader-invalid-pe:"))

    def test_import_parser_named_and_ordinal(self):
        imports = monitor.parse_dwm_imports(self.payload)
        self.assertTrue(imports.present)
        self.assertEqual(imports.names, {"DwmIsCompositionEnabled"})
        self.assertEqual(imports.ordinals, {103})

    def test_import_parser_bounds(self):
        malformed = bytearray(self.payload)
        struct.pack_into("<I", malformed, 0x3C, 0xFFFFFFF0)
        with self.assertRaises(monitor.PeError):
            monitor.parse_dwm_imports(malformed)

    def test_delay_import_additions_must_also_be_exported(self):
        data = bytearray(self.payload)
        optional = 0x98
        struct.pack_into("<II", data, optional + 112 + 13 * 8, 0x1140, 64)
        struct.pack_into("<IIIIIIII", data, 0x340, 1, 0x1190, 0, 0x11D0, 0x11D0, 0, 0, 0)
        data[0x390:0x39B] = b"dwmapi.dll\0"
        struct.pack_into("<QQ", data, 0x3D0, 0x1200, 0)
        raw = b"\0\0DwmFutureFunction\0"
        data[0x400:0x400 + len(raw)] = raw
        self.configure_network(bytes(data))
        report, _ = self.check()
        self.assertEqual(report["status"], "unsupported")
        self.assertIn("name:DwmFutureFunction", report["reason"])

    def test_proxy_noname_is_not_a_named_export(self):
        names, ordinals = monitor.proxy_exports(self.definition)
        self.assertNotIn("forward_1", names)
        self.assertIn(103, ordinals)

    def test_probe_refusal_is_reported_but_probe_crash_is_not(self):
        rejected = lambda command, **kwargs: subprocess.CompletedProcess(command, 1, "x64=1 scan=unknown", "")
        report, _ = self.check(runner=rejected)
        self.assertEqual(report["status"], "unsupported")
        old = self.output.read_bytes()
        crashed = lambda command, **kwargs: subprocess.CompletedProcess(command, 2, "", "usage failure")
        with self.assertRaises(monitor.ProbeError):
            self.check(fingerprint="d" * 64, runner=crashed)
        self.assertEqual(self.output.read_bytes(), old)

    def test_unchanged_unsupported_result_can_skip_download(self):
        rejected = lambda command, **kwargs: subprocess.CompletedProcess(command, 1, "x64=1 scan=unknown", "")
        self.check(runner=rejected)
        self.network.calls.clear()
        report, skipped = self.check()
        self.assertTrue(skipped)
        self.assertEqual(report["status"], "unsupported")
        self.assertEqual(self.network.calls, [monitor.MANIFEST_URL])

    def test_incomplete_probe_success_does_not_create_report(self):
        incomplete = lambda command, **kwargs: subprocess.CompletedProcess(command, 0, "x64=1", "")
        with self.assertRaises(monitor.ProbeError):
            self.check(runner=incomplete)
        self.assertFalse(self.output.exists())

    def test_unsupported_reason_is_bounded_for_the_updater(self):
        rejected = lambda command, **kwargs: subprocess.CompletedProcess(command, 1, "x64=1 scan=" + "x" * 4000, "")
        report, _ = self.check(runner=rejected)
        self.assertEqual(report["status"], "unsupported")
        self.assertLessEqual(len(report["reason"]), 512)
        self.assertNotIn("\n", report["reason"])
        self.assertTrue(report["reason"].startswith("scanner-refused:"))
        self.configure_network(synthetic_pe(names=("DwmFuture" + "x" * 400,)))
        loader, _ = self.check()
        self.assertEqual(loader["status"], "unsupported")
        self.assertLessEqual(len(loader["reason"]), 512)

    def test_wrong_final_hash_does_not_create_report(self):
        self.manifest["sha256"] = "0" * 64
        self.sync_manifest()
        with self.assertRaises(monitor.IntegrityError):
            self.check()
        self.assertFalse(self.output.exists())

    def test_wrong_final_or_part_size(self):
        self.manifest["size"] += 1
        self.sync_manifest()
        with self.assertRaises(monitor.IntegrityError):
            self.check()
        self.configure_network(self.payload)
        self.manifest["parts"][0]["size"] += 1
        self.sync_manifest()
        with self.assertRaises(monitor.IntegrityError):
            self.check()

    def test_optional_part_size_still_has_total_limit(self):
        for part in self.manifest["parts"]:
            part.pop("size")
        self.sync_manifest()
        self.assertEqual(self.check()[0]["status"], "structural_only")
        with mock.patch.object(monitor, "MAX_COMPRESSED_BYTES", 1):
            with self.assertRaises(monitor.IntegrityError):
                self.check(fingerprint="d" * 64)

    def test_bad_gzip_and_expansion_bound(self):
        parsed = monitor.parse_manifest(json.dumps(self.manifest).encode())
        for part in parsed["parts"]:
            self.routes[part["url"]] = b"x" * part["size"]
        with self.assertRaises(monitor.IntegrityError):
            self.check()
        self.configure_network(self.payload)
        self.manifest["size"] = 4
        self.sync_manifest()
        with self.assertRaises(monitor.IntegrityError):
            self.check()

    def test_network_error_keeps_existing_report(self):
        self.check()
        old = self.output.read_bytes()
        self.routes[monitor.safe_url(self.manifest["parts"][0]["url"], relative=True)] = URLError("network down")
        with self.assertRaises(monitor.DownloadError):
            self.check(fingerprint="d" * 64)
        self.assertEqual(self.output.read_bytes(), old)

    def test_rejects_foreign_and_unsafe_urls(self):
        bad = ("http://wow.aethus.pl/exe/a", "https://example.com/exe/a", "//example.com/exe/a",
            "https://user@wow.aethus.pl/exe/a", "https://wow.aethus.pl:444/exe/a",
            "../a", "%2e%2e/a", "a?secret=1", "a#fragment", "a\\b", "/download/game.rar",
            "https://[/exe/a")
        for url in bad:
            with self.subTest(url=url), self.assertRaises(monitor.ManifestError):
                monitor.safe_url(url, relative=True)

    def test_manifest_limits_and_wrong_types(self):
        for field, value in (("size", True), ("size", monitor.MAX_EXE_BYTES + 1), ("sha256", "bad"),
                             ("parts", []), ("parts", [{}] * 33)):
            changed = dict(self.manifest)
            changed[field] = value
            with self.subTest(field=field), self.assertRaises(monitor.ManifestError):
                monitor.parse_manifest(json.dumps(changed).encode())
        with self.assertRaises(monitor.ManifestError):
            monitor.parse_manifest(b" " * (monitor.MAX_MANIFEST_BYTES + 1))
        with self.assertRaises(monitor.ManifestError):
            monitor.parse_manifest(b'{"size":1,"size":2}')
        changed = dict(self.manifest)
        changed["parts"] = [{"url": "0.130.0/a", "size": True}]
        with self.assertRaises(monitor.ManifestError):
            monitor.parse_manifest(json.dumps(changed).encode())
        changed["parts"] = [{"url": "0.130.0/a", "size": monitor.MAX_COMPRESSED_BYTES},
                            {"url": "0.130.0/b", "size": 1}]
        with self.assertRaises(monitor.ManifestError):
            monitor.parse_manifest(json.dumps(changed).encode())

    def test_engine_identity_hashes_relevant_blobs_not_head(self):
        blobs = "\n".join(str(index) * 40 for index in range(1, len(monitor.SCANNER_FILES) + 1))
        def response(head, object_text=blobs):
            def run(command, **kwargs):
                value = head if "rev-parse" in command else object_text
                return subprocess.CompletedProcess(command, 0, value, "")
            return run
        with mock.patch.object(monitor.subprocess, "run", response("a" * 40)):
            first_commit, first = monitor.source_identity(ROOT)
        with mock.patch.object(monitor.subprocess, "run", response("b" * 40)):
            second_commit, second = monitor.source_identity(ROOT)
        self.assertNotEqual(first_commit, second_commit)
        self.assertEqual(first, second)
        with mock.patch.object(monitor.subprocess, "run", response("b" * 40, blobs.replace("1", "9"))):
            self.assertNotEqual(first, monitor.source_identity(ROOT)[1])
        self.assertIn("native/proxy.def", monitor.SCANNER_FILES)
        self.assertIn("tools/check_game_compatibility.py", monitor.SCANNER_FILES)


if __name__ == "__main__":
    unittest.main(verbosity=2)
