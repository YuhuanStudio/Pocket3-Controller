#!/usr/bin/env python3
"""Opt-in real Sparkle old→new installation using isolated, locally signed App copies.

Default is a read-only plan. No production updater key/feed/preferences are used.
"""
from __future__ import annotations

import argparse
import base64
import ctypes
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from xml.sax.saxutils import escape

from product_metadata import APP_NAME, BUNDLE_IDENTIFIER, metadata

PROJECT = Path(__file__).resolve().parents[1]
PREFIX = BUNDLE_IDENTIFIER + ".UpdateFixture.install."
BRIDGE = Path.home() / "Library/Application Support/Pocket3Bridge"
SENTINELS = {"Pocket3SelectedPage": "engines", "Pocket3CapturePixelFormat": "nv12",
             "com.yuhuanstudio.yunaudio.appearance": "dark", "Pocket3PermissionGuideShown": True,
             "updatePermissionHasLaunched": True, "updatePermissionDecision": "manual",
             "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def run(label, arguments, *, timeout=60, environment=None):
    try:
        result = subprocess.run([str(x) for x in arguments], capture_output=True, timeout=timeout,
                                env=environment, check=False)
    except (OSError, subprocess.SubprocessError):
        raise RuntimeError(label + " could not complete") from None
    require(result.returncode == 0, f"{label} failed (exit {result.returncode})")
    return result.stdout


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def read_info(app):
    path = app / "Contents/Info.plist"
    require(path.is_file() and not path.is_symlink(), "Missing or indirect App Info.plist")
    return plistlib.loads(path.read_bytes())


def app_tree(app):
    root = app.resolve()
    require(app.is_dir() and not app.is_symlink(), "Use a real App bundle, not an alias")
    entries = {}
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            require(path.resolve().is_relative_to(root), "App contains an external resource link")
            entries[relative] = {"link": os.readlink(path)}
        elif path.is_file():
            entries[relative] = {"bytes": path.stat().st_size, "sha256": digest(path)}
    return entries


def tree_hash(entries):
    return hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def process_path(pid):
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    buffer = ctypes.create_string_buffer(4096)
    if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        try:
            os.kill(pid, 0) # Existence check only; no signal is delivered.
        except ProcessLookupError:
            return None
        except PermissionError:
            pass
        raise RuntimeError("Cannot identify a running Pocket3MCP process")
    return Path(os.fsdecode(buffer.value)).resolve()


def pocket_processes():
    result = subprocess.run(["/usr/bin/pgrep", "-x", "Pocket3MCP"], capture_output=True, text=True, timeout=5)
    require(result.returncode in (0, 1), "Cannot enumerate Pocket3MCP processes")
    found = {}
    for value in result.stdout.split():
        pid = int(value)
        path = process_path(pid)
        if path is not None:
            found[pid] = path
    return found


def only_fixture(host):
    found = pocket_processes()
    expected = (host / "Contents/MacOS/Pocket3MCP").resolve()
    require(all(path == expected for path in found.values()), "Another Pocket3MCP started; fixture stopped without touching that process")
    return found


def token_metadata():
    # Never read/export the token. The App's normal startup owns this fixed IPC path.
    path = BRIDGE / "connection-token"
    try:
        info = path.stat(follow_symlinks=False)
        return (info.st_ino, info.st_mtime_ns, info.st_size)
    except FileNotFoundError:
        return None


def wait_until(label, check, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.2)
    raise RuntimeError(label + " timed out")


def fixture_domain(identifier):
    require(re.fullmatch(re.escape(PREFIX) + r"[0-9a-f]{32}", identifier) is not None,
            "Refusing a non-fixture preference domain")
    return identifier


def preferences(identifier):
    result = subprocess.run(["/usr/bin/defaults", "export", fixture_domain(identifier), "-"],
                            capture_output=True, timeout=10)
    if result.returncode:
        return None
    return plistlib.loads(result.stdout)


def set_preferences(identifier):
    for key, value in SENTINELS.items():
        kind = "-bool" if type(value) is bool else "-string"
        text = str(value).lower() if type(value) is bool else value
        run("Write isolated preference", ["/usr/bin/defaults", "write", fixture_domain(identifier), key, kind, text], timeout=10)
    require(all(preferences(identifier).get(k) == v for k, v in SENTINELS.items()), "Fixture preferences were not persisted")


def quit_fixture(host):
    target = (host / "Contents/MacOS/Pocket3MCP").resolve()
    own = [pid for pid, path in pocket_processes().items() if path == target]
    if not own:
        return True
    # A dynamic argument avoids interpolating paths into AppleScript source.
    run("Quit exact fixture App", ["/usr/bin/osascript", "-e", "on run argv", "-e",
        "tell application (item 1 of argv) to quit", "-e", "end run", str(host)], timeout=15)
    wait_until("Fixture graceful termination", lambda: not any(path == target for path in pocket_processes().values()), 15)
    return True


def customize(app, identifier, feed_url, public_key):
    info = read_info(app)
    info.update(CFBundleIdentifier=fixture_domain(identifier), SUFeedURL=feed_url, SUPublicEDKey=public_key,
                SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True, SUEnableAutomaticChecks=False,
                SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False, SUEnableSystemProfiling=False,
                SUEnableDownloaderService=False, SUSignedFeedFailureExpirationInterval=0,
                NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))


def serve(resources, requests, unexpected):
    lock = threading.Lock()
    class Handler(BaseHTTPRequestHandler):
        def do_HEAD(self):
            self.respond(False)
        def do_GET(self):
            self.respond(True)
        def respond(self, body):
            path = urlsplit(self.path).path
            if path not in resources or self.headers.get("Range"):
                with lock:
                    unexpected.append({"path": path[:256], "rangeRequested": self.headers.get("Range") is not None})
                self.send_error(404)
                return
            source, content_type = resources[path]
            length = source.stat().st_size
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(length))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            sent = 0; checksum = hashlib.sha256(); complete = not body
            try:
                if body:
                    with source.open("rb") as stream:
                        for chunk in iter(lambda: stream.read(256 * 1024), b""):
                            self.wfile.write(chunk); sent += len(chunk); checksum.update(chunk)
                    self.wfile.flush(); complete = sent == length
            except (BrokenPipeError, ConnectionResetError):
                pass
            with lock:
                requests.append({"path": path, "method": "GET" if body else "HEAD", "bytes": sent,
                                 "sha256": checksum.hexdigest() if body else None, "complete": complete})
        def log_message(self, *_):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    require(server.server_port >= 1024, "Unexpected privileged loopback port")
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def write_report(output, report):
    temporary = output / "result.json.tmp"
    temporary.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    temporary.replace(output / "result.json")


def execute(old_archive, candidate, output):
    require(sys.platform == "darwin", "Installation verification requires macOS")
    require(not pocket_processes(), "Quit every production/fixture Pocket3MCP before --execute; this script never quits production Apps")
    require(old_archive.is_file() and not old_archive.is_symlink(), "Old archive must be a regular ZIP")
    source_info = read_info(candidate); identity = metadata(source_info)
    require(source_info.get("Pocket3BuildConfiguration") == "release", "Candidate must be an existing Release build")
    require(output.is_relative_to((PROJECT / "artifacts").resolve()) and not os.path.lexists(output),
            "--output must be a new directory under this repository's artifacts/")
    output.mkdir(parents=True, mode=0o700)
    report = {"status": "running", "passed": False, "runID": uuid.uuid4().hex, "startedAt": timestamp(),
              "cameraUsed": False, "network": "127.0.0.1 only", "target": identity,
              "scope": "real Sparkle external driver; isolated re-signed old and candidate App copies",
              "notChecked": ["production AppUpdateController UI", "production update private key and online feed",
                             "unmodified production signatures", "cross-Mac quarantine/Gatekeeper", "camera and model use"],
              "sharedIPCPathUsed": True, "productionPreferencesModified": False, "requests": [], "cleanup": {}}
    write_report(output, report)
    workspace = Path(tempfile.mkdtemp(prefix="pocket3-update-install-")).resolve()
    workspace.chmod(0o700)
    identifier = PREFIX + uuid.uuid4().hex
    host = workspace / "installed" / APP_NAME
    new_app = workspace / "candidate" / APP_NAME
    keys = workspace / "keys"
    events = workspace / "driver-events.jsonl"
    server = None; driver = None; terminal = {}; app_launched = False
    environment = dict(os.environ)
    for key in ["POCKET3_UPDATE_CHECK", "POCKET3_UPDATE_FIXTURE", "POCKET3_ICON", "POCKET3_RESOURCE_CHECK", "POCKET3_BRIDGE_DIRECTORY"]:
        environment.pop(key, None)
    if "DEVELOPER_DIR" not in environment and Path("/Applications/Xcode-beta.app/Contents/Developer").exists():
        environment["DEVELOPER_DIR"] = "/Applications/Xcode-beta.app/Contents/Developer"
    try:
        source_tree = app_tree(candidate)
        report["sourceCandidateTreeSHA256"] = tree_hash(source_tree)
        report["sourceOldArchiveSHA256"] = digest(old_archive)
        spec = importlib.util.spec_from_file_location("release_archive_check", PROJECT / "Scripts/verify-release-artifacts.py")
        verifier = importlib.util.module_from_spec(spec); spec.loader.exec_module(verifier)
        report["oldArchiveInspection"] = verifier.inspect_zip(old_archive)
        run("Extract old fixture", ["/usr/bin/ditto", "-x", "-k", old_archive, host.parent])
        old_info = read_info(host); old_identity = metadata(old_info)
        require(int(old_identity["buildVersion"]) < int(identity["buildVersion"]), "Candidate build must be newer than the old archive")
        report["old"] = old_identity
        run("Copy candidate fixture", ["/usr/bin/ditto", candidate, new_app])
        app_tree(host); app_tree(new_app)
        keys.mkdir(mode=0o700)
        run("Generate ephemeral fixture key", ["/usr/bin/xcrun", "swift", PROJECT / "Scripts/make-update-fixture-key.swift", keys], environment=environment)
        public_key = (keys / "public-key.txt").read_text().strip()
        require(len(base64.b64decode(public_key, validate=True)) == 32, "Invalid ephemeral public key")
        resources = {}; unexpected = []
        server = serve(resources, report["requests"], unexpected)
        prefix = "/" + report["runID"]
        feed_path, archive_path = prefix + "/appcast.xml", prefix + "/candidate.zip"
        base_url = f"http://127.0.0.1:{server.server_port}"
        signing = json.loads(run("Prepare local fixture signing", [sys.executable, "-B", PROJECT / "Scripts/local-signing.py", "--prepare"]))
        for app in (host, new_app):
            customize(app, identifier, base_url + feed_path, public_key)
            run("Sign fixture copy", ["/usr/bin/codesign", "--force", "--deep", "--sign", signing["identity"],
                "--keychain", signing["keychain"], "--timestamp=none", app])
            run("Verify fixture signature", ["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
        expected_tree = app_tree(new_app)
        report["resignedCandidateTreeSHA256"] = tree_hash(expected_tree)
        report["resignedCandidateExecutableSHA256"] = digest(new_app / "Contents/MacOS/Pocket3MCP")
        archive = workspace / "candidate.zip"
        run("Package resigned candidate", ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", new_app, archive])
        archive_hash, archive_bytes = digest(archive), archive.stat().st_size
        require(0 < archive_bytes <= 1024**3, "Fixture archive exceeds 1 GiB")
        signer = PROJECT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
        secret = keys / "private-key.txt"
        signature = run("Sign fixture archive", [signer, "--ed-key-file", secret, "-p", archive]).decode().strip()
        run("Verify fixture archive", [signer, "--verify", "--ed-key-file", secret, archive, signature])
        feed = workspace / "appcast.xml"
        feed.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<title>Isolated Pocket 3 Update Installation</title><item><title>Fixture build {escape(identity['buildVersion'])}</title>
<sparkle:version>{escape(identity['buildVersion'])}</sparkle:version><sparkle:shortVersionString>{escape(identity['version'])}</sparkle:shortVersionString>
<sparkle:channel>beta</sparkle:channel><sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
<enclosure url="{base_url + archive_path}" length="{archive_bytes}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
</item></channel></rss>\n''')
        run("Sign fixture feed", [signer, "--ed-key-file", secret, "--disable-signing-warning", feed])
        run("Verify fixture feed", [signer, "--verify", "--ed-key-file", secret, feed])
        report["fixtureArchive"] = {"bytes": archive_bytes, "sha256": archive_hash}
        report["fixtureFeedSHA256"] = digest(feed)
        resources.update({feed_path: (feed, "application/rss+xml"), archive_path: (archive, "application/zip")})
        executable = workspace / "update-install-driver"
        frameworks = new_app / "Contents/Frameworks"
        run("Compile standalone driver", ["/usr/bin/xcrun", "clang", "-fobjc-arc", "-fblocks", "-Wall", "-Wextra", "-Werror",
            "-framework", "Foundation", "-framework", "AppKit", "-F", frameworks, "-framework", "Sparkle",
            "-Wl,-rpath," + str(frameworks), PROJECT / "Scripts/update-install-driver.m", "-o", executable], environment=environment)
        set_preferences(identifier)
        require(not pocket_processes(), "A Pocket3MCP started while fixtures were prepared; refusing launch")
        token_before = token_metadata()
        run("Launch old fixture", ["/usr/bin/open", "-n", host, "--args", "--hardware-validation"], environment=environment)
        app_launched = True
        def old_ready():
            found = only_fixture(host)
            return next(iter(found)) if len(found) == 1 and token_metadata() not in (None, token_before) else None
        old_pid = wait_until("Old fixture startup and fresh IPC", old_ready, 20)
        old_token = token_metadata()
        report["oldPID"] = old_pid
        with (output / "driver.stdout.log").open("wb") as stdout, (output / "driver.stderr.log").open("wb") as stderr:
            driver = subprocess.Popen([str(executable), "--host", str(host), "--events", str(events),
                "--expected-version", identity["buildVersion"], "--workspace", str(workspace)],
                stdout=stdout, stderr=stderr, env=environment)
            deadline = time.monotonic() + 120
            while driver.poll() is None:
                only_fixture(host)
                require(time.monotonic() < deadline, "Standalone updater exceeded its installation deadline")
                time.sleep(0.2)
        report["driverExitCode"] = driver.returncode
        require(events.is_file() and not events.is_symlink() and events.stat().st_size <= 2 * 1024**2, "Missing or oversized driver events")
        shutil.copyfile(events, output / "driver-events.jsonl")
        callbacks = [json.loads(line) for line in events.read_text().splitlines()]
        endings = [event for event in callbacks if event.get("type") == "driver_finished"]
        require(len(endings) == 1, "Driver did not report exactly one terminal event")
        terminal = endings[0]; report["driver"] = terminal
        require(driver.returncode == 0 and terminal.get("success") is True
                and all(terminal.get(key) is True for key in ["feedSignatureVerified", "archiveDownloaded", "installationPerformed", "relaunched"]),
                "Sparkle did not complete verified download, installation and relaunch")
        require(terminal.get("expectedVersion") == identity["buildVersion"] and terminal.get("oldPID") == old_pid, "Driver identity mismatch")
        found = only_fixture(host)
        new_pid = terminal.get("newPID")
        require(type(new_pid) is int and new_pid != old_pid and set(found) == {new_pid}, "Old PID did not exit or new fixture PID/path differs")
        report["oldExitedAndNewFixturePIDVerified"] = True; report["newPID"] = new_pid
        installed_info = read_info(host)
        require(installed_info.get("CFBundleIdentifier") == identifier and installed_info.get("CFBundleVersion") == identity["buildVersion"], "Installed fixture identity/build differs")
        installed_tree = app_tree(host)
        report["installedTreeSHA256"] = tree_hash(installed_tree)
        report["installedCandidateBytesMatch"] = installed_tree == expected_tree
        require(report["installedCandidateBytesMatch"], "Installed App bytes differ from the resigned candidate")
        run("Verify installed signature", ["/usr/bin/codesign", "--verify", "--deep", "--strict", host])
        report["installedSignatureVerified"] = True
        values = preferences(identifier) or {}
        report["preferencesPreserved"] = all(values.get(key) == value for key, value in SENTINELS.items())
        require(report["preferencesPreserved"], "Known App preferences were lost during installation")
        wait_until("New fixture fresh IPC", lambda: token_metadata() not in (None, old_token), 10)
        only_fixture(host)
        # Exactly one normal helper status call; no connect, photo, AI or UVC query.
        state = json.loads(run("Read installed fixture IPC", [host / "Contents/MacOS/pocket3", "status"], timeout=15, environment=environment))
        capture = state.get("capture", {})
        report["freshIPC"] = {"appVersion": state.get("appVersion"), "phase": state.get("phase"),
            "access": state.get("access"), "frames": capture.get("frames"), "selected": state.get("selected") is not None,
            "motionActive": state.get("motionActive"), "tokenMetadataChanged": True, "statusCalls": 1}
        require(state.get("appVersion") == identity["semanticVersion"] and state.get("phase") in {"idle", "disconnected", "paused"}
                and state.get("access") == "manual" and state.get("selected") is None
                and capture.get("frames") == 0 and capture.get("frame") is None and state.get("motionActive") is False,
                "Installed App IPC is not the fresh, disconnected candidate")
        downloads = [r for r in report["requests"] if r["path"] == archive_path and r["method"] == "GET"]
        report["downloadBytesServed"] = sum(r["bytes"] for r in downloads)
        report["downloadBytesAndHashVerified"] = any(r["complete"] and r["bytes"] == archive_bytes and r["sha256"] == archive_hash for r in downloads)
        require(report["downloadBytesAndHashVerified"] and terminal.get("bytesDownloaded") == archive_bytes and not unexpected,
                "Actual loopback download bytes/hash or route differs")
        require(digest(old_archive) == report["sourceOldArchiveSHA256"] and app_tree(candidate) == source_tree,
                "Original release input changed during the fixture")
        report["productionInputsUnchanged"] = True
        report["passed"] = True
    except Exception as error:
        report["error"] = str(error)[:1200]
    finally:
        if driver is not None and driver.poll() is None:
            driver.terminate()
            try: driver.wait(timeout=5)
            except subprocess.TimeoutExpired: report["cleanup"]["driverStillRunning"] = True
        if server is not None:
            server.shutdown(); server.server_close()
        # A missing/failed terminal never proves an installer has stopped.
        # Retain the private workspace on any driver failure for root inspection.
        safe_to_remove = driver is None or (
            terminal.get("success") is True
            and terminal.get("installationMayStillBeRunning") is False
            and report.get("oldExitedAndNewFixturePIDVerified") is True)
        try:
            if events.is_file() and not events.is_symlink() and events.stat().st_size <= 2 * 1024**2:
                shutil.copyfile(events, output / "driver-events.jsonl")
        except OSError as error:
            report["cleanup"]["eventCopyError"] = error.strerror
        if app_launched:
            try:
                report["cleanup"]["fixtureQuit"] = quit_fixture(host)
                # Do not remove a live/relaunching fixture or an active install workspace.
                time.sleep(1)
                target = (host / "Contents/MacOS/Pocket3MCP").resolve()
                require(not any(path == target for path in pocket_processes().values()), "Fixture relaunched during cleanup")
            except Exception as error:
                safe_to_remove = False; report["cleanup"]["error"] = str(error)[:500]
        safe_to_remove = safe_to_remove and not report["cleanup"].get("driverStillRunning", False)
        # Ephemeral private material is removed even if an interrupted installer
        # requires retaining the otherwise-private App workspace for inspection.
        if keys.exists(): shutil.rmtree(keys)
        report["cleanup"]["ephemeralKeysRemoved"] = not keys.exists()
        try:
            subprocess.run(["/usr/bin/defaults", "delete", fixture_domain(identifier)], capture_output=True, timeout=10)
            report["cleanup"]["fixturePreferencesCleared"] = preferences(identifier) in (None, {})
        except Exception as error:
            report["cleanup"]["preferenceError"] = str(error)[:500]
        # Only this generated fixture's cache; never CorePaths/models or TCC.
        cache = Path.home() / "Library/Caches" / identifier
        if safe_to_remove and cache.is_dir() and not cache.is_symlink(): shutil.rmtree(cache)
        if safe_to_remove:
            shutil.rmtree(workspace)
            report["cleanup"]["workspaceRemoved"] = True
        else:
            report["cleanup"]["workspaceRetained"] = str(workspace)
        report["passed"] = bool(report["passed"] and safe_to_remove and report["cleanup"].get("fixturePreferencesCleared"))
        report["status"] = "complete" if report["passed"] else "failed"
        report["finishedAt"] = timestamp()
        write_report(output, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true", help="Opt in to isolated App launch, local update, relaunch and cleanup")
    parser.add_argument("--old-archive", type=Path, default=PROJECT / "dist/github-release/0.0.1-beta.1/Pocket3Controller-0.0.1-beta.1.zip")
    parser.add_argument("--candidate", type=Path, default=PROJECT / "dist" / APP_NAME)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = (args.output or PROJECT / "artifacts/update-install" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex)).resolve()
    if not args.execute:
        print(json.dumps({"status": "plan_only", "executed": False, "oldArchive": str(args.old_archive.absolute()),
            "candidate": str(args.candidate.absolute()), "output": str(output), "requiresAllPocket3MCPStopped": True,
            "driverArguments": ["--host", "--events", "--expected-version", "--workspace"],
            "network": "127.0.0.1 only", "cameraUsed": False}, indent=2))
        return 0
    os.umask(0o077)
    try:
        report = execute(args.old_archive.absolute(), args.candidate.absolute(), output)
        print(json.dumps({"passed": report["passed"], "status": report["status"], "output": str(output)}, indent=2))
        return 0 if report["passed"] else 1
    except Exception as error:
        print(json.dumps({"status": "rejected", "passed": False, "error": str(error)[:1200]}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
