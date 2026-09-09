#!/usr/bin/env python3
"""Read public Beta identity and local git provenance without modifying git."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

DISPLAY_NAME = "Pocket 3 Controller"
APP_NAME = DISPLAY_NAME + ".app"
BUNDLE_IDENTIFIER = "studio.yuhuan.Pocket3Bridge"
EXECUTABLE = "Pocket3MCP"


def metadata(info):
    if info.get("CFBundleDisplayName") != DISPLAY_NAME or info.get("CFBundleName") != DISPLAY_NAME:
        raise ValueError("The Beta must use the Pocket 3 Controller display name")
    if info.get("CFBundleIdentifier") != BUNDLE_IDENTIFIER or info.get("CFBundleExecutable") != EXECUTABLE:
        raise ValueError("Bundle identifier and executable must retain the existing app identity")
    version = info.get("CFBundleShortVersionString")
    build = info.get("CFBundleVersion")
    channel = info.get("Pocket3ReleaseChannel")
    number = info.get("Pocket3PrereleaseNumber")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Expected a three-component numeric app version")
    if not isinstance(build, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", build):
        raise ValueError("Expected a numeric bundle build version")
    if channel != "beta" or type(number) is not int or not 1 <= number <= 9999:
        raise ValueError("Beta packaging requires a beta channel and positive prerelease number")
    semantic = f"{version}-{channel}.{number}"
    return {"displayName": DISPLAY_NAME, "appBundleName": APP_NAME, "version": version,
            "buildVersion": build, "releaseChannel": channel, "prereleaseNumber": number,
            "displayVersion": f"{version} {channel} {number}", "semanticVersion": semantic,
            "archiveStem": f"Pocket3Controller-{semantic}"}


def source_metadata(project):
    """Local builds may be dirty/unborn; only affirmative clean provenance is releasable."""
    unknown = {"sourceCommit": None, "sourceDirty": True, "sourceClean": False}
    project = Path(project).resolve()

    def read(arguments):
        result = subprocess.run(["git", "--no-optional-locks", "-C", str(project), *arguments],
            capture_output=True, text=True, timeout=15, check=False,
            env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
        if result.returncode or len(result.stdout) > 1024 * 1024:
            return None
        return result.stdout.strip()

    try:
        top = read(["rev-parse", "--show-toplevel"])
        if top is None or Path(top).resolve() != project:
            return unknown
        head = read(["rev-parse", "--verify", "HEAD^{commit}"])
        if head is None or re.fullmatch(r"[0-9a-f]{40,64}", head) is None:
            return unknown
        changes = read(["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"])
        same_head = read(["rev-parse", "--verify", "HEAD^{commit}"]) == head
    except (OSError, subprocess.SubprocessError):
        return unknown
    if not same_head:
        return unknown
    dirty = changes is None or bool(changes)
    return {"sourceCommit": head, "sourceDirty": dirty, "sourceClean": not dirty}


def build_source_metadata(before, after):
    """A source change during assembly can never turn into a clean build claim."""
    commit = before["sourceCommit"] if before["sourceCommit"] == after["sourceCommit"] else None
    clean = commit is not None and before["sourceClean"] is True and after["sourceClean"] is True
    return {"sourceCommit": commit, "sourceDirty": not clean, "sourceClean": clean}


def staged_source_metadata(info):
    commit = info.get("Pocket3SourceCommit") or None
    dirty = info.get("Pocket3SourceDirty", True)
    clean = info.get("Pocket3SourceClean", False)
    if (commit is not None and (not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40,64}", commit) is None)
            or type(dirty) is not bool or type(clean) is not bool or clean == dirty
            or clean and commit is None):
        raise ValueError("Invalid staging source provenance")
    return {"sourceCommit": commit, "sourceDirty": dirty, "sourceClean": clean}


def validate_public_settings(value):
    # Reuse the allowlist validator; this module never opens a signing key.
    spec = importlib.util.spec_from_file_location("pocket3_public_release_settings", Path(__file__).with_name("release-settings.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    result = module.settings(value)
    if not all(result.get(key) for key in ("Pocket3RepositoryURL", "SUFeedURL", "SUPublicEDKey")):
        raise ValueError("Public Beta packaging requires repository and signed update feed configuration")
    return result


def configured_update_settings(info):
    expected = validate_public_settings({"repositoryURL": info.get("Pocket3RepositoryURL"),
        "feedURL": info.get("SUFeedURL"), "publicEDKey": info.get("SUPublicEDKey")})
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError("The App must require signed feeds and verify updates before extraction")
    return expected


def read_metadata(path):
    return metadata(plistlib.loads(Path(path).read_bytes()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("info_plist", type=Path, nargs="?")
    parser.add_argument("--field")
    parser.add_argument("--source-project", type=Path, help="Read git provenance only; no key or media access")
    args = parser.parse_args()
    try:
        if args.source_project:
            if args.info_plist:
                raise ValueError("Choose a plist or --source-project, not both")
            result = source_metadata(args.source_project)
        else:
            if args.info_plist is None:
                raise ValueError("An Info.plist or --source-project is required")
            result = read_metadata(args.info_plist)
        if args.field:
            if args.field not in result:
                raise ValueError("Unknown public metadata field")
            print(result[args.field])
        else:
            print(json.dumps(result, ensure_ascii=False))
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))


if __name__ == "__main__":
    main()
