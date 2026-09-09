#!/usr/bin/env python3
"""Verify packaged ZIP/DMG payloads without launching the App or using a camera."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
from product_metadata import APP_NAME, metadata as product_metadata, staged_source_metadata, configured_update_settings


PROJECT = Path(__file__).resolve().parents[1]
MAX_UNPACKED_BYTES = 8 * 1024**3
MAX_ZIP_ENTRIES = 100_000


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def save_report(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".release-verification-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def command(arguments, timeout=90):
    started = time.monotonic()
    result = subprocess.run(arguments, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    metadata = {"returnCode": result.returncode, "seconds": time.monotonic() - started,
                "stderr": result.stderr.decode("utf-8", errors="replace")[-6000:]}
    return result, metadata


def checked_command(arguments, timeout=90):
    result, metadata = command(arguments, timeout)
    require(result.returncode == 0, f"{Path(arguments[0]).name} failed ({result.returncode}): {metadata['stderr']}")
    return result, metadata


def verify_file(path, entry):
    require(path.is_file() and not path.is_symlink(), f"Artifact is not a regular file: {path.name}")
    actual_size = path.stat().st_size
    require(actual_size == entry["bytes"], f"Artifact size mismatch: {path.name}")
    actual_hash = sha256(path)
    require(actual_hash == entry["sha256"], f"Artifact SHA-256 mismatch: {path.name}")
    return {"file": path.name, "bytes": actual_size, "sha256": actual_hash, "verified": True}


def inspect_zip(path):
    """Check member/link paths before ditto preserves macOS bundle symlinks."""
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        require(0 < len(entries) <= MAX_ZIP_ENTRIES, "ZIP member count exceeds the validation bound")
        total = 0
        for entry in entries:
            name = entry.filename
            member = PurePosixPath(name)
            require(name == entry.orig_filename and "\x00" not in name and "\\" not in name,
                    "ZIP contains an ambiguous member name")
            require(not member.is_absolute() and ".." not in member.parts and member.parts,
                    f"ZIP member escapes extraction root: {name}")
            require(member.parts[0] in (APP_NAME, "__MACOSX"), f"Unexpected ZIP top-level payload: {name}")
            require(not entry.flag_bits & 1, "Encrypted ZIP entries are not supported")
            mode = stat.S_IFMT(entry.external_attr >> 16)
            require(mode in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), f"Unsupported ZIP file kind: {name}")
            total += entry.file_size
            require(total <= MAX_UNPACKED_BYTES, "ZIP exceeds the 8 GiB unpacked validation bound")
            if mode == stat.S_IFLNK:
                require(entry.file_size <= 4096, f"Oversized ZIP symlink: {name}")
                target = archive.read(entry).decode("utf-8")
                require(target and "\x00" not in target and not target.startswith("/"), f"External ZIP symlink: {name}")
                resolved = posixpath.normpath(posixpath.join(str(member.parent), target))
                require(resolved == APP_NAME or resolved.startswith(APP_NAME + "/"),
                        f"ZIP symlink escapes the App: {name}")
        return {"entries": len(entries), "unpackedBytes": total}


def verify_app(app, manifest):
    require(app.is_dir() and not app.is_symlink(), f"Missing packaged {APP_NAME}")
    root = app.resolve()
    # App-contained framework aliases are expected; external build-tree links
    # would make this a nonportable payload even if the source bundle signed.
    for path in app.rglob("*"):
        if path.is_symlink():
            require(path.resolve().is_relative_to(root), f"App symlink escapes its bundle: {path.relative_to(app)}")
    info_path = app / "Contents/Info.plist"
    require(info_path.is_file() and not info_path.is_symlink(), "App Info.plist is missing or indirect")
    info = plistlib.loads(info_path.read_bytes())
    identity = product_metadata(info)
    source = staged_source_metadata(info)
    update_settings = configured_update_settings(info)
    require(manifest.get("updateSettings") == update_settings, "Packaged update settings differ from manifest")
    for key, value in source.items():
        require(key in manifest and manifest[key] == value and type(manifest[key]) is type(value),
                f"Packaged source provenance mismatch: {key}")
    for key in ("displayName", "appBundleName", "version", "buildVersion", "releaseChannel", "prereleaseNumber", "displayVersion", "semanticVersion", "archiveStem"):
        require(identity[key] == manifest.get(key), f"Packaged product metadata mismatch: {key}")
    require(info.get("CFBundleShortVersionString") == manifest["version"], "App version does not match manifest")
    require(info.get("CFBundleVersion") == manifest["buildVersion"], "App build does not match manifest")
    require(info.get("Pocket3BuildConfiguration") == "release", "Packaged App is not a Release build")
    executable_name = info.get("CFBundleExecutable")
    require(executable_name == "Pocket3MCP", "Unexpected App executable")
    executable = app / "Contents/MacOS" / executable_name
    require(executable.is_file() and not executable.is_symlink(), "App executable is missing or indirect")
    executable_hash = sha256(executable)
    require(executable_hash == manifest["appExecutableSHA256"], "App executable SHA-256 does not match manifest")
    helper = app / "Contents/MacOS/pocket3"
    require(helper.is_file() and not helper.is_symlink(), "Packaged MCP helper is missing or indirect")
    helper_hash = sha256(helper)
    if "helperExecutableSHA256" in manifest:
        require(helper_hash == manifest["helperExecutableSHA256"], "MCP helper SHA-256 does not match manifest")
    _, signature = checked_command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    return {**identity, **source, "updateSettings": update_settings,
            "bundleIdentifier": info.get("CFBundleIdentifier"), "configuration": info["Pocket3BuildConfiguration"],
            "appExecutableSHA256": executable_hash, "helperExecutableSHA256": helper_hash,
            "codesign": signature, "verified": True}


def attached_device_for(image):
    """Find only the image copied into our unique private temporary directory."""
    result, _ = checked_command(["/usr/bin/hdiutil", "info", "-plist"], timeout=20)
    for item in plistlib.loads(result.stdout).get("images", []):
        image_path = item.get("image-path")
        if not isinstance(image_path, str) or Path(image_path).resolve() != image.resolve():
            continue
        devices = [entity.get("dev-entry", "") for entity in item.get("system-entities", [])]
        device = next((value for value in devices if re.fullmatch(r"/dev/disk\d+", value)),
                      next((value for value in devices if re.fullmatch(r"/dev/disk\d+(?:s\d+)+", value)), None))
        require(device is not None, "The private image remains attached without a recognizable device entry")
        return device
    return None


def detach_owned_image(mount, image):
    cleanup = {"detached": False, "attempts": []}
    try:
        result, metadata = command(["/usr/bin/hdiutil", "detach", str(mount)], timeout=30)
        cleanup["attempts"].append({"target": str(mount), **metadata})
        if result.returncode == 0 and not os.path.ismount(mount) and attached_device_for(image) is None:
            cleanup["detached"] = True
            return cleanup
    except Exception as error:
        cleanup["attempts"].append({"target": str(mount), "error": str(error)})
    try:
        device = attached_device_for(image)
        if device is None:
            cleanup["detached"] = not os.path.ismount(mount)
            cleanup["alreadyDetachedOrNeverAttached"] = cleanup["detached"]
            return cleanup
        # Only this script's unique copy may be force-detached. Never select an
        # arbitrary existing image or another user's mount by volume name.
        result, metadata = command(["/usr/bin/hdiutil", "detach", "-force", device], timeout=30)
        cleanup["attempts"].append({"target": device, "force": True, **metadata})
        cleanup["detached"] = result.returncode == 0 and not os.path.ismount(mount) and attached_device_for(image) is None
    except Exception as error:
        cleanup["error"] = str(error)
    return cleanup


def verify_dmg(source, entry, manifest, record):
    workspace = Path(tempfile.mkdtemp(prefix="pocket3-release-dmg-"))
    mount = workspace / "mount"
    mount.mkdir(mode=0o700)
    image = workspace / "verified-image.dmg"
    attach_attempted = False
    cleanup = {"detached": True, "attachNotAttempted": True}
    failure = None
    try:
        # An independent path/inode avoids reusing or detaching a preexisting
        # mount of the user's original release DMG.
        shutil.copyfile(source, image)
        verify_file(image, entry)
        attach_attempted = True
        result, metadata = checked_command(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse",
                                            "-mountpoint", str(mount), "-plist", str(image)], timeout=90)
        record["attach"] = {**metadata, "readOnlyRequested": True, "noBrowseRequested": True}
        entities = plistlib.loads(result.stdout).get("system-entities", [])
        owned = [item for item in entities if isinstance(item.get("mount-point"), str)
                 and Path(item["mount-point"]).resolve() == mount.resolve()]
        require(len(owned) == 1 and os.path.ismount(mount), "DMG was not mounted at the requested private mount point")
        record["mountedDevice"] = owned[0].get("dev-entry")
        applications = mount / "Applications"
        require(applications.is_symlink() and os.readlink(applications) == "/Applications",
                "DMG Applications entry is not a symlink to /Applications")
        record["applicationsSymlink"] = "/Applications"
        require(not os.path.lexists(mount / "Pocket 3 MCP.app"), "The repository compatibility alias must not enter the DMG")
        record["app"] = verify_app(mount / APP_NAME, manifest)
    except Exception as error:
        failure = error
    finally:
        if attach_attempted:
            cleanup = detach_owned_image(mount, image)
        record["cleanup"] = cleanup
        if cleanup["detached"]:
            shutil.rmtree(workspace)
        else:
            # Do not recurse through a still-mounted volume. Preserve its
            # private workspace and exact mount path for explicit cleanup.
            record["retainedWorkspace"] = str(workspace)
            record["retainedMountPoint"] = str(mount)
    if failure is not None:
        raise failure
    require(cleanup["detached"], "DMG verification finished but its private mount could not be detached")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=PROJECT / "dist/release-artifacts.json")
    parser.add_argument("--output", type=Path, default=PROJECT / "artifacts/release-artifacts-verification.json")
    args = parser.parse_args()
    manifest_path = args.manifest.resolve()
    output = args.output.resolve()
    report = {"status": "running", "passed": False, "verified": False, "runID": str(uuid.uuid4()),
              "startedAt": timestamp(), "manifest": str(manifest_path), "appLaunched": False,
              "cameraUsed": False, "artifacts": {}}
    save_report(output, report)
    try:
        require(sys.platform == "darwin", "Release bundle verification requires macOS codesign, ditto and hdiutil")
        require(manifest_path.is_file() and manifest_path.stat().st_size <= 1024 * 1024, "Release manifest is missing or oversized")
        manifest_data = manifest_path.read_bytes()
        report["manifestSHA256"] = hashlib.sha256(manifest_data).hexdigest()
        manifest = json.loads(manifest_data)
        require(isinstance(manifest, dict), "Release manifest must be an object")
        report["manifestBuildVersion"] = manifest.get("buildVersion")
        report["manifestVersion"] = manifest.get("version")
        report["manifestDisplayVersion"] = manifest.get("displayVersion")
        report["releaseChannel"] = manifest.get("releaseChannel")
        report["prereleaseNumber"] = manifest.get("prereleaseNumber")
        report["manifestAppExecutableSHA256"] = manifest.get("appExecutableSHA256")
        save_report(output, report)
        require(manifest.get("status") == "complete" and manifest.get("verified") is True, "Packaging manifest is not complete")
        for key in ("version", "buildVersion"):
            require(isinstance(manifest.get(key), str) and manifest[key], f"Manifest lacks required {key}")
        require(manifest.get("releaseChannel") == "beta" and type(manifest.get("prereleaseNumber")) is int
                and 1 <= manifest["prereleaseNumber"] <= 9999, "Expected Beta prerelease metadata")
        require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", manifest["version"]) is not None, "Invalid Beta version")
        expected_stem = f"Pocket3Controller-{manifest['version']}-beta.{manifest['prereleaseNumber']}"
        require(manifest.get("archiveStem") == expected_stem, "Unexpected Beta archive stem")
        require(manifest.get("displayVersion") == f"{manifest['version']} beta {manifest['prereleaseNumber']}", "Unexpected Beta display version")
        require(isinstance(manifest.get("appExecutableSHA256"), str)
                and re.fullmatch(r"[0-9a-f]{64}", manifest["appExecutableSHA256"]), "Manifest lacks a valid App executable SHA-256")
        entries = manifest.get("artifacts")
        require(isinstance(entries, list) and len(entries) == 2, "Expected exactly one ZIP and one DMG artifact")
        payloads = {}
        for entry in entries:
            require(isinstance(entry, dict), "Invalid artifact entry")
            name = entry.get("file")
            require(isinstance(name, str) and name and Path(name).name == name and "\\" not in name, "Invalid artifact filename")
            suffix = Path(name).suffix.lower()
            require(suffix in (".zip", ".dmg") and suffix not in payloads, "Expected one unique ZIP and one unique DMG")
            require(name == expected_stem + suffix, "Artifact filename does not match the Beta metadata")
            require(type(entry.get("bytes")) is int and entry["bytes"] > 0, "Artifact size must be a positive integer")
            require(isinstance(entry.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]), "Invalid artifact SHA-256")
            source = manifest_path.parent / name
            record = verify_file(source, entry)
            report["artifacts"][suffix[1:]] = record
            payloads[suffix] = (source, entry)
        save_report(output, report)

        source, entry = payloads[".zip"]
        with tempfile.TemporaryDirectory(prefix="pocket3-release-zip-") as temporary:
            workspace = Path(temporary)
            archive = workspace / "verified-image.zip"
            shutil.copyfile(source, archive)
            verify_file(archive, entry)
            details = inspect_zip(archive)
            require(shutil.disk_usage(workspace).free >= details["unpackedBytes"] + 32 * 1024**2, "Insufficient temporary disk space for ZIP verification")
            extracted = workspace / "payload"
            extracted.mkdir(mode=0o700)
            _, extraction = checked_command(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], timeout=120)
            report["artifacts"]["zip"].update({"archive": details, "extraction": extraction, "app": verify_app(extracted / APP_NAME, manifest)})
        save_report(output, report)

        source, entry = payloads[".dmg"]
        verify_dmg(source, entry, manifest, report["artifacts"]["dmg"])
        zip_app = report["artifacts"]["zip"]["app"]
        dmg_app = report["artifacts"]["dmg"]["app"]
        require(zip_app["helperExecutableSHA256"] == dmg_app["helperExecutableSHA256"], "ZIP and DMG contain different MCP helper executables")
        require(sha256(manifest_path) == report["manifestSHA256"], "Manifest changed during verification")
        for source, entry in payloads.values():
            verify_file(source, entry)
        report.update(status="complete", passed=True, verified=True, manifestUnchanged=True, artifactsUnchanged=True)
    except Exception as error:
        report.update(status="failed", passed=False, verified=False, error={"type": type(error).__name__, "message": str(error)})
    finally:
        report["finishedAt"] = timestamp()
        save_report(output, report)
    print(json.dumps({"passed": report["passed"], "status": report["status"], "report": str(output),
                      "manifestBuildVersion": report.get("manifestBuildVersion"), "error": report.get("error")}, ensure_ascii=False, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
