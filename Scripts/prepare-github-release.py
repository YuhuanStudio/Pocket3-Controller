#!/usr/bin/env python3
"""Prepare a reviewable GitHub Beta release locally; never publish or modify git.

Only the verified ZIP, DMG, checksums and curated release notes become assets.
The evidence reports and release plan stay local. No signing keys are accessed.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import subprocess

from product_metadata import APP_NAME, metadata, staged_source_metadata, configured_update_settings, validate_public_settings

PROJECT = Path(__file__).resolve().parents[1]
REQUIRED_CHECKS = {
    "build", "unit tests", "shared design", "translations",
    "isolated Sparkle signed-feed verification", "portable resources",
    "live layout", "window and popover lifetime",
    "copied-app MLX and Core AI inference", "model memory release",
    "offline MCP", "MCP cancellation", "ZIP/DMG assembly", "DMG checksum",
    "extracted ZIP and read-only DMG payload signatures and hashes",
    "source provenance and release preflight",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def regular_file(path):
    require(path.is_file() and not path.is_symlink(), f"Missing or indirect input: {path.name}")
    return path


def digest(path):
    value = hashlib.sha256()
    with regular_file(path).open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def document(path):
    require(regular_file(path).stat().st_size <= 1024 * 1024, f"Oversized metadata: {path.name}")
    value = json.loads(path.read_bytes())
    require(isinstance(value, dict), f"Expected an object: {path.name}")
    return value


def repository_name(value):
    require(isinstance(value, str) and re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}", value),
        "--repo must be an explicit GitHub OWNER/REPOSITORY without a URL or credentials")
    require(value.lower() != "yuhuanstudio/yunaudio", "Do not publish this app into YunAudio")
    return value


def git_read(project, arguments):
    # Optional locks are disabled so status cannot refresh the index on disk.
    result = subprocess.run(["git", "--no-optional-locks", "-C", str(project), *arguments],
        capture_output=True, text=True, timeout=15, check=False,
        env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
    require(result.returncode == 0, "Local git prerequisite failed: " + arguments[0])
    require(len(result.stdout) <= 1024 * 1024, "Oversized git response")
    return result.stdout.strip()


def source_identity(project, tag):
    require(Path(git_read(project, ["rev-parse", "--show-toplevel"])).resolve() == project.resolve(),
        "The project must be the git worktree root")
    head = git_read(project, ["rev-parse", "--verify", "HEAD^{commit}"])
    require(re.fullmatch(r"[0-9a-f]{40,64}", head), "Invalid local HEAD")
    tagged = git_read(project, ["rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"])
    require(tagged == head, "The exact release tag must point to HEAD")
    dirty = git_read(project, ["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"])
    require(not dirty, "Source is not clean; commit or remove intended source changes before preparing a release")
    return {"commit": head, "tag": tag, "clean": True, "tagMatchesHEAD": True}


def collect(project, repository):
    repository = repository_name(repository)
    app = project / "dist" / APP_NAME
    require(app.is_dir() and not app.is_symlink(), "Use the real Controller bundle, not its compatibility alias")
    info_path = regular_file(app / "Contents/Info.plist")
    info = plistlib.loads(info_path.read_bytes())
    identity = metadata(info)
    require(info.get("Pocket3BuildConfiguration") == "release", "App must be a Release build")
    source_info = plistlib.loads(regular_file(project / "Resources/Info.plist").read_bytes())
    require(metadata(source_info) == identity, "The built App identity differs from the current source Info.plist")
    tag = "v" + identity["semanticVersion"]
    source = source_identity(project, tag)
    expected_source = {"sourceCommit": source["commit"], "sourceDirty": False, "sourceClean": True}
    require(staged_source_metadata(info) == expected_source,
        "App source commit/clean status differs from the exact tagged clean source")
    checked_in_settings = validate_public_settings(document(project / "Resources/ReleaseSettings.json"))
    require(configured_update_settings(info) == checked_in_settings,
        "App update configuration differs from checked-in public ReleaseSettings.json")
    require(checked_in_settings["Pocket3RepositoryURL"].rstrip("/") == "https://github.com/" + repository,
        "The release repository differs from the configured product repository")

    manifest_path = project / "dist/release-artifacts.json"
    gate_path = project / "artifacts/verification-gate.json"
    payload_path = project / "artifacts/release-artifacts-verification.json"
    manifest, gate, payload = (document(path) for path in (manifest_path, gate_path, payload_path))
    require(manifest.get("status") == "complete" and manifest.get("verified") is True,
        "Packaging manifest has not completed")
    require(manifest.get("updateSettings") == checked_in_settings,
        "Packaged update settings differ from the checked-in release configuration")
    require(gate.get("status") == "complete" and gate.get("passed") is True
        and gate.get("configuration") == "release", "The full Release gate has not passed")
    require(isinstance(gate.get("checks"), list) and all(isinstance(item, str) for item in gate["checks"])
        and REQUIRED_CHECKS.issubset(gate["checks"]), "Gate omitted required UI, model, MCP or package checks")
    require(payload.get("status") == "complete" and payload.get("passed") is True
        and payload.get("verified") is True and payload.get("manifestUnchanged") is True
        and payload.get("artifactsUnchanged") is True, "ZIP/DMG payload verification has not passed")
    for record, label in ((manifest, "manifest"), (gate, "gate")):
        require(all(record.get(key) == value for key, value in identity.items()),
            f"Product metadata differs between App and {label}")
        require(all(record.get(key) == value for key, value in expected_source.items())
                and record.get("sourceDirty") is False and record.get("sourceClean") is True,
            f"Recorded build source commit or clean status differs from HEAD in {label}")
    require(gate.get("sourceUnchangedDuringGate") is True, "Source changed during the Release gate")
    require(isinstance(gate.get("runID"), str) and gate["runID"], "Gate lacks its run ID")
    require(isinstance(payload.get("runID"), str) and payload["runID"]
        and gate.get("releaseArtifactRunID") == payload["runID"], "Gate refers to a different payload verification run")
    require(payload.get("manifestSHA256") == digest(manifest_path), "Manifest changed after payload verification")
    app_hash = digest(app / "Contents/MacOS/Pocket3MCP")
    helper_hash = digest(app / "Contents/MacOS/pocket3")
    require(manifest.get("appExecutableSHA256") == gate.get("appExecutableSHA256") == app_hash
        and payload.get("manifestAppExecutableSHA256") == app_hash, "App executable does not match gate/package evidence")
    require(manifest.get("helperExecutableSHA256") == helper_hash, "MCP helper differs from the package manifest")
    require(payload.get("manifestBuildVersion") == identity["buildVersion"], "Payload verification build differs")
    require(isinstance(manifest.get("signing"), str) and manifest["signing"]
        and manifest["signing"] == info.get("Pocket3SigningKind"), "Signing kind differs from the packaged App")
    require(type(manifest.get("notarized")) is bool, "Manifest must state notarisation explicitly")

    source["binarySourceCommitRecorded"] = True

    entries = manifest.get("artifacts")
    require(isinstance(entries, list) and len(entries) == 2, "Only one ZIP and one DMG may be released")
    assets, found = [], set()
    for entry in entries:
        require(isinstance(entry, dict), "Invalid artifact entry")
        name = entry.get("file")
        require(isinstance(name, str), "Artifact name is missing")
        extension = Path(name).suffix
        require(extension in (".zip", ".dmg") and extension not in found
            and name == identity["archiveStem"] + extension, "Artifact is outside the ZIP/DMG allowlist")
        found.add(extension)
        path = regular_file(manifest_path.parent / name)
        require(type(entry.get("bytes")) is int and entry["bytes"] > 0
            and path.stat().st_size == entry["bytes"], "Artifact size differs from manifest")
        require(digest(path) == entry.get("sha256"), "Artifact SHA-256 differs from manifest")
        detail = payload.get("artifacts", {}).get(extension[1:], {})
        require(detail.get("verified") is True
            and all(detail.get(key) == entry[key] for key in ("file", "bytes", "sha256")),
            "Archive differs from the verified payload")
        packaged_app = detail.get("app", {})
        require(packaged_app.get("verified") is True and packaged_app.get("appExecutableSHA256") == app_hash
            and packaged_app.get("helperExecutableSHA256") == helper_hash,
            "Packaged App/helper differ from the current App")
        require(all(packaged_app.get(key) == value for key, value in expected_source.items())
                and packaged_app.get("sourceDirty") is False and packaged_app.get("sourceClean") is True,
            "Packaged App source provenance differs from the release source")
        require(packaged_app.get("updateSettings") == checked_in_settings,
            "Packaged App update settings differ from the release configuration")
        assets.append({"file": name, "bytes": entry["bytes"], "sha256": entry["sha256"]})

    notes_path = regular_file(project / "docs/releases" / (identity["semanticVersion"] + ".md"))
    require(notes_path.stat().st_size <= 128 * 1024, "Release notes are oversized")
    notes = notes_path.read_text(encoding="utf-8")
    require(notes.startswith("# " + identity["displayName"] + " " + identity["displayVersion"] + "\n"),
        "Curated notes must name this exact product and Beta version")
    warnings = []
    if not manifest["notarized"]:
        warnings.append("This Beta is not notarised. Local signing is not Developer ID or Apple distribution approval.")
    plan = {"status": "local_preflight_passed", "published": False, "remoteChecked": False,
        "repository": repository, "repositoryURL": "https://github.com/" + repository,
        "releaseURL": f"https://github.com/{repository}/releases/tag/{tag}",
        "source": source, **identity, "signing": manifest["signing"],
        "notarizedDeclaredByManifest": manifest["notarized"], "warnings": warnings,
        "signedUpdateFeedConfigured": True, "feedURL": checked_in_settings["SUFeedURL"],
        "appExecutableSHA256": app_hash, "helperExecutableSHA256": helper_hash,
        "gateRunID": gate["runID"], "payloadVerificationRunID": payload["runID"],
        "evidenceSHA256": {"gate": digest(gate_path), "manifest": digest(manifest_path),
            "payloadVerification": digest(payload_path), "curatedReleaseNotes": digest(notes_path),
            "publicReleaseSettings": digest(project / "Resources/ReleaseSettings.json")},
        "assets": sorted(assets, key=lambda item: item["file"]),
        "notPerformed": ["remote tag/commit comparison", "GitHub repository creation", "GitHub release creation",
            "public download verification", "signed feed publication", "update installation"]}
    return plan, notes


def prepare(project, repository, output=None, check=False):
    project = Path(project).resolve()
    plan, notes = collect(project, repository)
    if check:
        return plan
    output = Path(output) if output else project / "dist/github-release" / plan["semanticVersion"]
    require(output.is_absolute(), "--output must be an absolute path")
    require(not os.path.lexists(output), "Output already exists; use a new review directory")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir(mode=0o700)
    # No globs: screenshots, reports, credentials and release-plan.json cannot
    # accidentally become assets. A later build cannot replace these snapshots.
    for asset in plan["assets"]:
        shutil.copyfile(project / "dist" / asset["file"], output / asset["file"])
        require(digest(output / asset["file"]) == asset["sha256"], "Archive changed while copying")
    notes += ("\n## 本次套件驗證\n\n"
        f"- Build：{plan['buildVersion']}\n- 簽署：`{plan['signing']}`；"
        f"manifest 公證標記：`{str(plan['notarizedDeclaredByManifest']).lower()}`。\n"
        f"- App SHA-256：`{plan['appExecutableSHA256']}`\n"
        f"- 原始碼 commit：`{plan['source']['commit']}`；建置來源與版本 tag 一致且乾淨。\n"
        "- 完整本機軟體 gate 與 ZIP／DMG payload 驗證通過；不代表所有機身功能已驗收。\n")
    notes_name = "release-notes.md"
    (output / notes_name).write_text(notes, encoding="utf-8")
    notes_asset = {"file": notes_name, "bytes": (output / notes_name).stat().st_size,
        "sha256": digest(output / notes_name)}
    checksums_name = "checksums-" + plan["semanticVersion"] + ".txt"
    checksums = "".join(f"{item['sha256']}  {item['file']}\n" for item in [*plan["assets"], notes_asset])
    (output / checksums_name).write_text(checksums, encoding="utf-8")
    plan["assets"] += [notes_asset, {"file": checksums_name,
        "bytes": (output / checksums_name).stat().st_size, "sha256": digest(output / checksums_name)}]
    # Fail closed if evidence/source changed while reading/copying, leaving only
    # an incomplete review directory without a release command on failure.
    recheck, _ = collect(project, repository)
    for key in ("source", "evidenceSHA256", "appExecutableSHA256", "helperExecutableSHA256"):
        require(recheck[key] == plan[key], "Source or evidence changed while preparing the release")
    argv = ["gh", "release", "create", plan["source"]["tag"],
        *["./" + item["file"] for item in plan["assets"]], "--repo", repository,
        "--title", plan["displayName"] + " " + plan["displayVersion"],
        "--draft", "--prerelease", "--verify-tag", "--latest=false", "--notes-file", "./" + notes_name]
    plan.update(status="prepared_locally", preparedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        command={"cwd": str(output), "argv": argv, "shellPreview": shlex.join(argv), "executed": False},
        localOnlyFiles=["release-plan.json"])
    (output / "release-plan.json").write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return plan


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="Explicit GitHub OWNER/REPOSITORY; no network request is made")
    parser.add_argument("--check", action="store_true", help="Validate only; create no files")
    parser.add_argument("--output", type=Path, help="New absolute output directory; existing paths are never overwritten")
    args = parser.parse_args()
    try:
        print(json.dumps(prepare(PROJECT, args.repo, args.output, args.check), ensure_ascii=False, indent=2))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"status": "rejected", "published": False, "error": str(error)}, ensure_ascii=False))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
