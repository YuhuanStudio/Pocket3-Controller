#!/usr/bin/env python3
"""Exercise the real app's Sparkle feed validation with isolated signed fixtures.

No camera, public hosting, production preference changes, or update installation.
Ephemeral update keys are files inside a private temporary directory, not Keychain entries.
"""
import base64
import atexit
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from product_metadata import read_metadata

root = pathlib.Path(__file__).resolve().parents[1]
source_app = root / "dist/Pocket 3 Controller.app"
signer = root / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
output = root / "artifacts/update-feed-verification"
output.mkdir(parents=True, exist_ok=True)


def run(arguments, **options):
    return subprocess.run([str(value) for value in arguments], check=True,
        capture_output=True, text=True, **options)


def preference_domain_cleanup_state(result, identifier):
    """defaults delete may retain an empty plist and export it successfully."""
    if result.returncode == 0:
        try:
            values = plistlib.loads(result.stdout.encode("utf-8"))
        except (ValueError, plistlib.InvalidFileException):
            return "unreadable"
        if not isinstance(values, dict):
            return "unreadable"
        return "empty" if not values else "not_empty"
    detail = result.stderr.lower()
    if identifier.lower() in detail and ("does not exist" in detail or "not found" in detail):
        return "absent"
    return "unreadable"


report = {"scope": "isolated real AppUpdateController and Sparkle signature verification",
    "publicFeedTested": False, "installationTested": False, "cameraUsed": False, "cases": {},
    "passed": False, "status": "running", "runID": str(uuid.uuid4()),
    "startedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "sourceExecutableSHA256": hashlib.sha256((source_app / "Contents/MacOS/Pocket3MCP").read_bytes()).hexdigest(),
    **read_metadata(source_app / "Contents/Info.plist")}
(output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
def record_incomplete_run():
    if report["status"] == "running":
        report["status"] = "failed"
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
atexit.register(record_incomplete_run)
with tempfile.TemporaryDirectory(prefix="pocket3-update-fixture-") as directory:
    temporary = pathlib.Path(directory)
    signing = json.loads(run(["python3", root / "Scripts/local-signing.py", "--prepare"]).stdout)
    keys = []
    for name in ("primary", "other"):
        folder = temporary / name
        folder.mkdir(mode=0o700)
        run(["xcrun", "swift", root / "Scripts/make-update-fixture-key.swift", folder])
        keys.append(folder)
    public_key = (keys[0] / "public-key.txt").read_text().strip()
    assert len(base64.b64decode(public_key, validate=True)) == 32
    archive = temporary / "fixture.bin"
    archive.write_bytes(b"Pocket 3 offline update-signature fixture\n")
    archive_length = archive.stat().st_size
    archive_signature = run([signer, "--ed-key-file", keys[0] / "private-key.txt", "-p", archive]).stdout.strip()
    run([signer, "--verify", "--ed-key-file", keys[0] / "private-key.txt", archive, archive_signature])
    archive.write_bytes(archive.read_bytes() + b"tampered")
    invalid_archive = subprocess.run([str(signer), "--verify", "--ed-key-file", str(keys[0] / "private-key.txt"),
        str(archive), archive_signature], capture_output=True, text=True)
    report["archiveTamperingRejected"] = invalid_archive.returncode != 0

    fixtures = {}
    counts = {}
    unexpected_requests = []
    class FixtureServer(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlsplit(self.path).path
            name = path.removeprefix("/").removesuffix(".xml")
            if name not in fixtures or path != "/" + name + ".xml":
                unexpected_requests.append(path)
                self.send_error(404)
                return
            counts[name] = counts.get(name, 0) + 1
            data = fixtures[name].read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/rss+xml")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        def log_message(self, *_):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureServer)
    serving = threading.Thread(target=server.serve_forever, daemon=True)
    serving.start()
    def close_server():
        server.shutdown()
        server.server_close()
    atexit.register(close_server)
    base_url = "http://127.0.0.1:" + str(server.server_port)

    xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>Fixture</title><item><title>Fixture version 1</title>
<sparkle:version>1</sparkle:version><sparkle:minimumSystemVersion>10.15.0</sparkle:minimumSystemVersion>
<enclosure url="{base_url}/fixture.zip" length="{archive_length}" type="application/octet-stream" sparkle:edSignature="{archive_signature}"/>
</item></channel></rss>\n'''
    for name, key in (("valid", keys[0]), ("wrong-key", keys[1])):
        path = temporary / (name + ".xml")
        path.write_text(xml)
        run([signer, "--ed-key-file", key / "private-key.txt", "--disable-signing-warning", path])
        fixtures[name] = path
    fixtures["tampered"] = temporary / "tampered.xml"
    fixtures["tampered"].write_text(fixtures["valid"].read_text().replace("Fixture", "Tamper!", 1))
    fixtures["unsigned"] = temporary / "unsigned.xml"
    fixtures["unsigned"].write_text(xml)

    app = temporary / "Pocket 3 Controller.app"
    run(["ditto", source_app, app])
    info_path = app / "Contents/Info.plist"
    original_info = plistlib.loads(info_path.read_bytes())
    for name, fixture in fixtures.items():
        identifier = "studio.yuhuan.Pocket3Bridge.UpdateFixture." + uuid.uuid4().hex
        info = dict(original_info)
        info.update(CFBundleIdentifier=identifier, SUFeedURL=base_url + "/" + name + ".xml",
            SUPublicEDKey=public_key, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
            SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
            SUSignedFeedFailureExpirationInterval=0,
            SUEnableDownloaderService=False, NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
        info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
        run(["codesign", "--force", "--deep", "--sign", signing["identity"], "--keychain", signing["keychain"],
            "--timestamp=none", app])
        environment = dict(os.environ)
        environment.update(POCKET3_UPDATE_CHECK="1", POCKET3_UPDATE_FIXTURE="loopback")
        result = subprocess.run([str(app / "Contents/MacOS/Pocket3MCP"), "--update-verification"],
            env=environment, capture_output=True, text=True, timeout=25)
        (output / (name + ".log")).write_text(result.stderr)
        try:
            evidence = json.loads(result.stdout)
        except json.JSONDecodeError:
            evidence = {"verified": False, "malformedOutput": True, "exitCode": result.returncode}
        evidence["exitCode"] = result.returncode
        evidence["fixtureRequests"] = counts.get(name, 0)
        (output / (name + ".json")).write_text(json.dumps(evidence, indent=2) + "\n")
        report["cases"][name] = evidence
        cache = pathlib.Path.home() / "Library/Caches" / identifier
        if cache.is_dir():
            shutil.rmtree(cache)
        print(json.dumps({"case": name, **evidence}), flush=True)

    # Exercise the actual AppEntry/verifier rejection path without touching
    # the production preference domain. Merely setting fixture environment
    # variables must not authorize updater startup or preference deletion.
    rejected_identifier = "studio.yuhuan.Pocket3Bridge.UpdateRejectionProbe." + uuid.uuid4().hex
    sentinel_key = "Pocket3UpdateVerificationSentinel"
    sentinel_value = uuid.uuid4().hex
    guard_evidence = {"passed": False, "isolatedPreferenceDomain": True}
    try:
        run(["/usr/bin/defaults", "write", rejected_identifier, sentinel_key, "-string", sentinel_value], timeout=10)
        assert run(["/usr/bin/defaults", "read", rejected_identifier, sentinel_key], timeout=10).stdout.strip() == sentinel_value
        info = dict(original_info)
        info.update(CFBundleIdentifier=rejected_identifier, SUFeedURL=base_url + "/valid.xml",
            SUPublicEDKey=public_key, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
            SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
            SUEnableDownloaderService=False, NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
        info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
        run(["codesign", "--force", "--deep", "--sign", signing["identity"], "--keychain", signing["keychain"],
            "--timestamp=none", app])
        before_requests = sum(counts.values()) + len(unexpected_requests)
        environment = dict(os.environ)
        environment.update(POCKET3_UPDATE_CHECK="1", POCKET3_UPDATE_FIXTURE="loopback")
        result = subprocess.run([str(app / "Contents/MacOS/Pocket3MCP"), "--update-verification"],
            env=environment, capture_output=True, text=True, timeout=10)
        (output / "non-fixture-bundle.log").write_text(result.stderr)
        try:
            guard_evidence.update(json.loads(result.stdout))
        except json.JSONDecodeError:
            guard_evidence["malformedOutput"] = True
        guard_evidence["exitCode"] = result.returncode
        # Recheck across a short bounded interval so asynchronous preference
        # deletion cannot be hidden by one immediate post-exit read.
        sentinel_checks = []
        for delay in (0, 0.1, 0.2):
            if delay:
                time.sleep(delay)
            sentinel = subprocess.run(["/usr/bin/defaults", "read", rejected_identifier, sentinel_key],
                capture_output=True, text=True, timeout=10)
            sentinel_checks.append(sentinel.returncode == 0 and sentinel.stdout.strip() == sentinel_value)
        guard_evidence["sentinelReadChecks"] = sentinel_checks
        guard_evidence["sentinelPreserved"] = all(sentinel_checks)
        guard_evidence["feedRequests"] = sum(counts.values()) + len(unexpected_requests) - before_requests
        guard_evidence["passed"] = bool(
            guard_evidence.get("verified") is False and guard_evidence.get("fixture") is False
            and guard_evidence.get("errorDomain") == "UpdateFixture" and guard_evidence.get("errorCode") == 1
            and guard_evidence.get("signatureStatus") is None and result.returncode == 1
            and guard_evidence.get("cameraServiceStarted") is False
            and guard_evidence.get("archiveDownloaded") is False and guard_evidence.get("installationPerformed") is False
            and guard_evidence["feedRequests"] == 0 and guard_evidence["sentinelPreserved"])
    finally:
        # This identifier was freshly generated above; never delete the
        # production bundle identifier or a caller-supplied preference domain.
        subprocess.run(["/usr/bin/defaults", "delete", rejected_identifier], capture_output=True, text=True, timeout=10)
        remaining = subprocess.run(["/usr/bin/defaults", "export", rejected_identifier, "-"],
            capture_output=True, text=True, timeout=10)
        cleanup_state = preference_domain_cleanup_state(remaining, rejected_identifier)
        guard_evidence["testDomainCleanupState"] = cleanup_state
        guard_evidence["testDomainRemoved"] = cleanup_state == "absent"
        guard_evidence["testDomainCleared"] = cleanup_state in {"absent", "empty"}
        guard_evidence["passed"] = bool(guard_evidence["passed"] and guard_evidence["testDomainCleared"])
        cache = pathlib.Path.home() / "Library/Caches" / rejected_identifier
        if cache.is_dir():
            shutil.rmtree(cache)
        report["nonFixtureBundleGuard"] = guard_evidence
        (output / "non-fixture-bundle.json").write_text(json.dumps(guard_evidence, indent=2) + "\n")
    print(json.dumps({"case": "non-fixture-bundle", **guard_evidence}), flush=True)
    valid = report["cases"]["valid"]
    report["passed"] = bool(report["archiveTamperingRejected"]
        and report["nonFixtureBundleGuard"].get("passed") is True
        and valid.get("verified") is True and valid.get("signatureStatus") == 1
        and valid.get("exitCode") == 0 and valid.get("fixtureRequests") == 1
        and all(value.get("verified") is False and value.get("fixtureRequests") == 1
            and value.get("exitCode") == 1 and value.get("errorDomain") == "SUSparkleErrorDomain"
            and value.get("errorCode") == 1000 and value.get("signatureStatus") != 1
            for name, value in report["cases"].items() if name != "valid")
        and all(value.get("cameraServiceStarted") is False and value.get("archiveDownloaded") is False
            and value.get("installationPerformed") is False for value in report["cases"].values())
        and not unexpected_requests)
    report["network"] = "loopback only"
    report["unexpectedRequests"] = unexpected_requests
    close_server()
    atexit.unregister(close_server)
report["status"] = "complete" if report["passed"] else "failed"
report["finishedAt"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
(output / "result.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"passed": report["passed"], "output": str(output)}))
raise SystemExit(0 if report["passed"] else 1)
