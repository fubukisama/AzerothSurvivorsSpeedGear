"""Check the official Windows EXE on a disposable CI runner; never run it.

Only this project's prebuilt AZSSpeedGearProbe is executed. Downloaded game
bytes stay in TemporaryDirectory and are never report/artifact contents.
"""
import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import gzip
import hashlib
from http.client import HTTPException
import json
import mmap
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit
from urllib.request import build_opener, HTTPRedirectHandler, Request
import zlib


PRODUCT = "AzerothSurvivorsSpeedGear"
SCANNER_CONTRACT = "rust-duration25ms-waitable-timer-v1"
ORIGIN = "https://wow.aethus.pl"
MANIFEST_URL = ORIGIN + "/exe/latest.json"
MAX_MANIFEST_BYTES = 64 * 1024
MAX_EXE_BYTES = 512 * 1024 * 1024
MAX_COMPRESSED_BYTES = 512 * 1024 * 1024
MAX_PARTS = 32
MAX_REASON_CHARS = 512
NETWORK_TIMEOUT = 30
DOWNLOAD_SECONDS = 600
PROBE_SECONDS = 120
CHUNK = 64 * 1024
SCANNER_FILES = (
    "native/pe_image.cpp", "native/include/pe_image.h", "native/probe.cpp",
    "native/proxy.def", "tools/check_game_compatibility.py",
)


class MonitorError(Exception):
    """An unavailable/invalid check; do not replace a prior report."""


class ManifestError(MonitorError):
    pass


class DownloadError(MonitorError):
    pass


class IntegrityError(MonitorError):
    pass


class ProbeError(MonitorError):
    pass


class PeError(ValueError):
    pass


def report_reason(value):
    # Keep public summaries short, single-line and safe for update clients.
    text = " ".join(str(value).split())
    text = "".join(c if 32 <= ord(c) <= 126 else "?" for c in text)
    if len(text) > MAX_REASON_CHARS:
        text = text[:MAX_REASON_CHARS - 3] + "..."
    return text or "Compatibility evidence was unavailable."


def safe_url(value, *, relative=False):
    if not isinstance(value, str) or not value or len(value) > 2048:
        raise ManifestError("invalid download URL")
    if any(ord(c) <= 32 or ord(c) > 126 for c in value) or "\\" in value or "%" in value:
        raise ManifestError("unsafe download URL characters")
    try:
        raw = urlsplit(value)
        if value.startswith("//") or any(p in (".", "..") for p in raw.path.split("/")):
            raise ManifestError("unsafe relative download URL")
        url = urljoin(MANIFEST_URL, value) if relative else value
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError as error:
        raise ManifestError("invalid download URL or port") from error
    if (parsed.scheme != "https" or parsed.hostname != "wow.aethus.pl"
            or port not in (None, 443) or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment
            or not parsed.path.startswith("/exe/") or "//" in parsed.path):
        raise ManifestError("download must stay on the official HTTPS /exe/ origin")
    return url


class OfficialRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        safe_url(newurl)
        return super().redirect_request(request, fp, code, message, headers, newurl)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON property")
        result[key] = value
    return result


def integer(value, label, maximum, minimum=1):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ManifestError(f"invalid {label}")
    return value


def parse_manifest(raw):
    if len(raw) > MAX_MANIFEST_BYTES:
        raise ManifestError("manifest exceeds 64 KiB")
    try:
        data = json.loads(raw.decode("utf-8-sig"), object_pairs_hook=unique_object)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ManifestError("invalid manifest JSON") from error
    if not isinstance(data, dict):
        raise ManifestError("manifest root is not an object")
    version = data.get("version")
    digest = data.get("sha256")
    if not isinstance(version, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+\-]{0,63}", version):
        raise ManifestError("invalid game version")
    if not isinstance(digest, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", digest):
        raise ManifestError("invalid final EXE SHA-256")
    size = integer(data.get("size"), "EXE size", MAX_EXE_BYTES)
    parts = data.get("parts")
    if not isinstance(parts, list) or not 1 <= len(parts) <= MAX_PARTS:
        raise ManifestError("manifest must contain 1..32 parts")
    normalized = []
    declared_total = 0
    for part in parts:
        if not isinstance(part, dict):
            raise ManifestError("part is not an object")
        url = safe_url(part.get("url"), relative=True)
        part_size = None
        if "size" in part:
            part_size = integer(part["size"], "part size", MAX_COMPRESSED_BYTES)
            declared_total += part_size
        normalized.append({"url": url, "size": part_size})
    if declared_total > MAX_COMPRESSED_BYTES:
        raise ManifestError("declared compressed total exceeds 512 MiB")
    return {"version": version, "size": size, "sha256": digest.lower(), "parts": normalized}


def open_official(opener, url, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise DownloadError("official download deadline exceeded")
    request = Request(safe_url(url), headers={
        "User-Agent": PRODUCT + "-compatibility-monitor/1",
        "Accept-Encoding": "identity",
    })
    try:
        response = opener.open(request, timeout=min(NETWORK_TIMEOUT, remaining))
        try:
            safe_url(response.geturl())
        except MonitorError:
            response.close()
            raise
        return response
    except (HTTPError, URLError, TimeoutError, OSError, HTTPException) as error:
        raise DownloadError("official HTTPS request failed: " + type(error).__name__) from error


def fetch_manifest(opener):
    try:
        deadline = time.monotonic() + NETWORK_TIMEOUT
        with open_official(opener, MANIFEST_URL, deadline) as response:
            read = getattr(response, "read1", response.read)
            pieces, length = [], 0
            while length <= MAX_MANIFEST_BYTES:
                if time.monotonic() > deadline:
                    raise DownloadError("official manifest deadline exceeded")
                chunk = read(min(CHUNK, MAX_MANIFEST_BYTES + 1 - length))
                if not chunk:
                    break
                pieces.append(chunk)
                length += len(chunk)
            raw = b"".join(pieces)
    except (HTTPError, URLError, TimeoutError, OSError, HTTPException) as error:
        raise DownloadError("official manifest I/O failed: " + type(error).__name__) from error
    return parse_manifest(raw)


def download_exe(manifest, directory, opener):
    compressed = Path(directory) / "official-payload.gz"
    executable = Path(directory) / "official-game.exe"
    total = 0
    deadline = time.monotonic() + DOWNLOAD_SECONDS
    try:
        with compressed.open("wb") as output:
            for part in manifest["parts"]:
                received = 0
                with open_official(opener, part["url"], deadline) as response:
                    # read1 returns available bytes rather than waiting to fill
                    # a chunk, so the total deadline also bounds slow trickles.
                    read = getattr(response, "read1", response.read)
                    while True:
                        if time.monotonic() > deadline:
                            raise DownloadError("official download deadline exceeded")
                        chunk = read(CHUNK)
                        if not chunk:
                            break
                        received += len(chunk)
                        total += len(chunk)
                        if total > MAX_COMPRESSED_BYTES:
                            raise IntegrityError("compressed download exceeds 512 MiB")
                        if part["size"] is not None and received > part["size"]:
                            raise IntegrityError("part exceeds its declared size")
                        output.write(chunk)
                if part["size"] is not None and received != part["size"]:
                    raise IntegrityError("part size does not match its manifest")
        digest = hashlib.sha256()
        expanded = 0
        with gzip.open(compressed, "rb") as source, executable.open("wb") as output:
            while True:
                chunk = source.read(CHUNK)
                if not chunk:
                    break
                expanded += len(chunk)
                if expanded > manifest["size"] or expanded > MAX_EXE_BYTES:
                    raise IntegrityError("expanded EXE exceeds its declared size")
                digest.update(chunk)
                output.write(chunk)
        if expanded != manifest["size"]:
            raise IntegrityError("final EXE size mismatch")
        if digest.hexdigest() != manifest["sha256"]:
            raise IntegrityError("final EXE SHA-256 mismatch")
        return executable
    except (gzip.BadGzipFile, EOFError, zlib.error) as error:
        raise IntegrityError("official payload is not a complete valid gzip stream") from error
    except (HTTPError, URLError, TimeoutError, OSError, HTTPException) as error:
        raise DownloadError("official payload I/O failed: " + type(error).__name__) from error


@dataclass
class DwmImports:
    present: bool
    names: set
    ordinals: set


def parse_dwm_imports(data):
    """Read x64 PE ordinary/delay import tables without loading executable code."""
    length = len(data)

    def require(offset, size):
        if offset < 0 or size < 0 or offset > length - size:
            raise PeError("out-of-bounds PE field")

    def unpack(fmt, offset):
        require(offset, struct.calcsize(fmt))
        return struct.unpack_from(fmt, data, offset)

    if length < 64 or data[:2] != b"MZ":
        raise PeError("not a PE file")
    pe, = unpack("<I", 0x3C)
    require(pe, 24)
    if data[pe:pe + 4] != b"PE\0\0":
        raise PeError("bad PE signature")
    machine, section_count = unpack("<HH", pe + 4)
    optional_size, = unpack("<H", pe + 20)
    optional = pe + 24
    require(optional, optional_size)
    magic, = unpack("<H", optional)
    if machine != 0x8664 or magic != 0x20B or not 1 <= section_count <= 96 or optional_size < 112:
        raise PeError("not a supported AMD64 PE32+ image")
    image_base, = unpack("<Q", optional + 24)
    headers, = unpack("<I", optional + 60)
    directory_count, = unpack("<I", optional + 108)
    sections = []
    for index in range(section_count):
        entry = optional + optional_size + index * 40
        require(entry, 40)
        virtual_size, rva, raw_size, raw_offset = unpack("<IIII", entry + 8)
        require(raw_offset, raw_size)
        sections.append((rva, max(virtual_size, raw_size), raw_offset, raw_size))

    def rva_offset(rva, size=1):
        if 0 <= rva < headers and rva + size <= min(headers, length):
            return rva
        for start, extent, raw, raw_size in sections:
            if start <= rva < start + extent and rva - start + size <= raw_size:
                require(raw + rva - start, size)
                return raw + rva - start
        raise PeError("unmapped PE RVA")

    def text(rva):
        offset = rva_offset(rva)
        end = data.find(b"\0", offset, min(length, offset + 512))
        if end < 0 or end == offset:
            raise PeError("invalid import string")
        try:
            return bytes(data[offset:end]).decode("ascii")
        except UnicodeError as error:
            raise PeError("non-ASCII import string") from error

    def directory(index):
        if directory_count <= index:
            return 0, 0
        if 112 + (index + 1) * 8 > optional_size:
            raise PeError("truncated PE directory table")
        return unpack("<II", optional + 112 + index * 8)

    names, ordinals = set(), set()

    def thunks(rva):
        if not rva:
            raise PeError("missing DWM thunk table")
        for index in range(8192):
            value, = unpack("<Q", rva_offset(rva + index * 8, 8))
            if not value:
                return
            if value & (1 << 63):
                if value & ~((1 << 63) | 0xFFFF):
                    raise PeError("invalid ordinal import")
                ordinals.add(value & 0xFFFF)
            else:
                if value > 0xFFFFFFFF:
                    raise PeError("invalid import-name RVA")
                rva_offset(value, 2)  # IMAGE_IMPORT_BY_NAME's hint
                names.add(text(value + 2))
        raise PeError("unterminated DWM thunk table")

    present = False
    start, size = directory(1)
    if start:
        terminated = False
        for index in range(min(size // 20, 4096)):
            fields = unpack("<IIIII", rva_offset(start + index * 20, 20))
            if not any(fields):
                terminated = True
                break
            original, _, _, name, first = fields
            if not name:
                raise PeError("missing import DLL name")
            if text(name).lower() == "dwmapi.dll":
                present = True
                thunks(original or first)
        if not terminated:
            raise PeError("unterminated ordinary imports")
    # Delay imports may request additional exports even when the ordinary table
    # already ensures that our proxy loads at startup.
    start, size = directory(13)
    if start:
        terminated = False
        for index in range(min(size // 32, 4096)):
            fields = unpack("<IIIIIIII", rva_offset(start + index * 32, 32))
            if not any(fields):
                terminated = True
                break
            attributes, name, _, _, lookup, _, _, _ = fields
            if not name:
                raise PeError("missing delay-import DLL name")
            if attributes & ~1:
                raise PeError("unknown delay-import attributes")
            if not attributes & 1:
                name -= image_base
                lookup -= image_base
            if text(name).lower() == "dwmapi.dll":
                thunks(lookup)
        if not terminated:
            raise PeError("unterminated delay imports")
    return DwmImports(present, names, ordinals)


def proxy_exports(path):
    names, ordinals = set(), set()
    active = False
    for raw in Path(path).read_text(encoding="utf-8-sig").splitlines():
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue
        if line.upper() == "EXPORTS":
            active = True
            continue
        if not active:
            continue
        fields = line.split()
        public = fields[0].split("=", 1)[0]
        ordinal = next((p for p in fields[1:] if re.fullmatch(r"@\d+", p)), None)
        if ordinal is None or not 1 <= int(ordinal[1:]) <= 65535:
            raise MonitorError("proxy.def has an unsupported export declaration")
        if any(p != ordinal and p.upper() not in ("NONAME", "PRIVATE", "DATA") for p in fields[1:]):
            raise MonitorError("proxy.def has unsupported export flags")
        ordinals.add(int(ordinal[1:]))
        if "NONAME" not in [p.upper() for p in fields[1:]]:
            names.add(public)
    if not active or not ordinals:
        raise MonitorError("proxy.def contains no exports")
    return names, ordinals


def check_loader(executable, definition):
    exported_names, exported_ordinals = proxy_exports(definition)
    try:
        with Path(executable).open("rb") as source:
            with mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as data:
                imports = parse_dwm_imports(data)
    except (PeError, ValueError, struct.error) as error:
        return False, "loader-invalid-pe: " + str(error)
    if not imports.present:
        return False, "loader-no-dwmapi: no ordinary dwmapi.dll import"
    missing = sorted("name:" + name for name in imports.names - exported_names)
    missing += ["ordinal:" + str(number) for number in sorted(imports.ordinals - exported_ordinals)]
    if missing:
        return False, "loader-missing-exports: " + ", ".join(missing)
    return True, "loader import/export requirements satisfied"


def run_probe(probe, executable, runner):
    try:
        result = runner([str(probe), str(executable), "--selftest"], capture_output=True,
                        text=True, encoding="utf-8", errors="replace", timeout=PROBE_SECONDS,
                        check=False, cwd=str(executable.parent))
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ProbeError("our compatibility probe could not complete") from error
    output = (result.stdout or "") + "\n" + (result.stderr or "")
    if result.returncode == 1:
        failures = {
            "Changed-duration fail-closed test failed": "scanner-selftest-failed: changed-duration negative check did not refuse",
            "Ambiguous-call fail-closed test failed": "scanner-selftest-failed: duplicate-call negative check did not refuse",
            "No executable fixture padding": "scanner-selftest-unavailable: no executable padding for the negative fixture",
        }
        for marker, explanation in failures.items():
            if marker in output:
                return "unsupported", explanation
        scan = re.search(r"\bscan=([^\r\n]+)", result.stdout or "")
        return "unsupported", ("scanner-refused: " + scan.group(1)) if scan else "scanner-refused: official EXE did not satisfy the supported scanner contract"
    if result.returncode != 0:
        raise ProbeError("our probe failed outside the supported refusal contract")
    if ("scanner-negative-tests=passed" not in output or "x64=1" not in output
            or not re.search(r"\bnanos=25000000\b", output)):
        raise ProbeError("our probe returned incomplete success evidence")
    return "structural_only", "Loader, unique simulation-wait scan and in-memory negative checks passed; gameplay is not verified."


def source_identity(root):
    def git(*arguments):
        try:
            return subprocess.run(["git", "-C", str(root), *arguments], capture_output=True,
                                  text=True, check=True, timeout=30).stdout.strip()
        except (OSError, subprocess.SubprocessError) as error:
            raise MonitorError("cannot determine scanner source identity") from error
    commit = git("rev-parse", "HEAD")
    blobs = git("hash-object", "--", *SCANNER_FILES).splitlines()
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit) or len(blobs) != len(SCANNER_FILES):
        raise MonitorError("invalid scanner Git identity")
    if any(not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", blob) for blob in blobs):
        raise MonitorError("invalid scanner Git blob identity")
    material = SCANNER_CONTRACT + "\n" + "".join(name + "\0" + blob + "\n" for name, blob in zip(SCANNER_FILES, blobs))
    return commit, hashlib.sha256(material.encode("utf-8")).hexdigest()


def cached_report(output, manifest, fingerprint):
    try:
        with Path(output).open("rb") as source:
            raw = source.read(MAX_MANIFEST_BYTES + 1)
        if len(raw) > MAX_MANIFEST_BYTES:
            return None
        report = json.loads(raw.decode("utf-8-sig"), object_pairs_hook=unique_object)
        if (type(report.get("schema")) is int and report.get("schema") == 1 and report.get("product") == PRODUCT
                and report.get("scannerContract") == SCANNER_CONTRACT
                and report.get("engineFingerprint") == fingerprint
                and report.get("gameSha256") == manifest["sha256"]
                and report.get("gameBytes") == manifest["size"]
                and report.get("gameVersion") == manifest["version"]
                and isinstance(report.get("reason"), str) and 1 <= len(report["reason"]) <= MAX_REASON_CHARS
                and report.get("status") in ("structural_only", "unsupported")):
            return report
    except (OSError, ValueError, UnicodeError, AttributeError, RecursionError):
        pass
    return None


def write_report(output, report):
    output = Path(output)
    if output.suffix.lower() != ".json" or output.is_symlink():
        raise MonitorError("output must be a regular JSON report path")
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=output.name + ".", suffix=".tmp", dir=output.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as target:
            json.dump(report, target, indent=2, ensure_ascii=True)
            target.write("\n")
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def monitor_once(*, probe, output, definition, fingerprint, commit, ci_run_id,
                 opener=None, runner=subprocess.run):
    opener = opener or build_opener(OfficialRedirects())
    manifest = fetch_manifest(opener)
    cached = cached_report(output, manifest, fingerprint)
    if cached is not None:
        return cached, True
    with tempfile.TemporaryDirectory(prefix="AZSSpeedGear-compat-") as directory:
        executable = download_exe(manifest, directory, opener)
        loadable, reason = check_loader(executable, definition)
        if loadable:
            status, reason = run_probe(probe, executable, runner)
        else:
            status = "unsupported"
        report = {
            "schema": 1, "product": PRODUCT, "scannerContract": SCANNER_CONTRACT,
            "gameVersion": manifest["version"], "gameSha256": manifest["sha256"],
            "gameBytes": manifest["size"], "status": status, "reason": report_reason(reason),
            "checkedUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "ciRunId": str(ci_run_id), "sourceCommit": commit, "engineFingerprint": fingerprint,
        }
    # Publish metadata only after downloaded files have left the temporary
    # context, including on Windows where open handles can prevent cleanup.
    write_report(output, report)
    return report, False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--probe", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    try:
        probe = args.probe.resolve(strict=True)
        if not probe.is_file() or probe.name.lower() != "azsspeedgearprobe.exe":
            raise MonitorError("--probe must name our prebuilt AZSSpeedGearProbe.exe")
        commit, fingerprint = source_identity(root)
        report, skipped = monitor_once(probe=probe, output=args.output,
            definition=root / "native/proxy.def", fingerprint=fingerprint, commit=commit,
            ci_run_id=os.environ.get("GITHUB_RUN_ID", "manual"))
        print(json.dumps({"status": report["status"], "skippedDownload": skipped,
                          "gameVersion": report["gameVersion"], "output": str(args.output)}))
        return 1 if report["status"] == "unsupported" else 0
    except (MonitorError, OSError) as error:
        print("Compatibility check unavailable; prior report unchanged: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
