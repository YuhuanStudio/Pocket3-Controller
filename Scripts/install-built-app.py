#!/usr/bin/env python3
"""Install a verified local bundle and preserve every displaced bundle/link.

Call only after staging and codesign verification. The compatibility alias is
restricted to this repository's dist directory and never enters a package.
"""
import argparse
import ctypes
import fcntl
import json
import os
from pathlib import Path
import stat
import uuid

from product_metadata import APP_NAME, read_metadata

LEGACY_NAME = "Pocket 3 MCP.app"


def exists(path):
    return os.path.lexists(path)


def unique_neighbor(destination, label):
    path = destination.parent / f".Pocket3Controller-{label}-{uuid.uuid4().hex}.bundle-backup"
    if exists(path):
        raise FileExistsError(path)
    return path


def exchange(source, destination):
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    rename = library.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000002):
        raise OSError(ctypes.get_errno(), "Could not atomically exchange the app bundles")


def install(source, destination):
    if source.is_symlink() or not source.is_dir():
        raise ValueError("The staged App must be a real bundle directory")
    if source == destination or source.is_relative_to(destination):
        raise ValueError("The staged bundle must be separate from the destination")
    read_metadata(source / "Contents/Info.plist")
    if exists(destination) and not (destination.is_symlink() or destination.is_dir()):
        raise ValueError("Refusing to replace a destination that is neither a bundle nor a symlink")

    # Keep incoming outside the build script's temporary directory. After a
    # swap, its trap must never delete the previous bundle, even on an error.
    incoming = unique_neighbor(destination, "incoming")
    source.rename(incoming)
    preserved = []
    if destination.is_symlink():
        # Do not resolve or exchange a link with the staged directory. Keeping
        # it in the same parent preserves the meaning of relative targets.
        backup = unique_neighbor(destination, "destination-link")
        destination.rename(backup); preserved.append(backup)
        try:
            incoming.rename(destination)
        except BaseException:
            if not exists(destination):
                backup.rename(destination)
            raise
    elif destination.exists():
        exchange(incoming, destination)
        backup = unique_neighbor(destination, "previous")
        try:
            incoming.rename(backup)
        except BaseException as error:
            raise RuntimeError(f"New App installed; previous bundle safely retained at {incoming}") from error
        preserved.append(backup)
    else:
        incoming.rename(destination)
    return preserved


def ensure_legacy_alias(destination, alias):
    if alias.is_symlink() and os.readlink(alias) == destination.name:
        return []
    if exists(alias) and not (alias.is_symlink() or alias.is_dir()):
        raise ValueError("Refusing to replace an unrelated file at the legacy App path")
    temporary = alias.parent / f".Pocket3Controller-alias-{uuid.uuid4().hex}"
    os.symlink(destination.name, temporary)
    backup = None
    try:
        if exists(alias):
            backup = unique_neighbor(destination, "legacy")
            alias.rename(backup)  # Preserve the actual old bundle/link, never delete its target.
        try:
            temporary.rename(alias)
        except BaseException:
            if backup is not None and not exists(alias):
                backup.rename(alias)
            raise
    finally:
        if temporary.is_symlink():
            temporary.unlink()  # Only our newly created temporary link.
    return [backup] if backup is not None else []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--legacy-alias", type=Path)
    args = parser.parse_args()
    source = Path(os.path.abspath(args.source))
    destination = Path(os.path.abspath(args.destination))
    if destination.name != APP_NAME:
        raise ValueError("The installed bundle must use the current product name")
    destination.parent.mkdir(parents=True, exist_ok=True)
    alias = Path(os.path.abspath(args.legacy_alias)) if args.legacy_alias else None
    if alias is not None:
        repository_dist = Path(__file__).resolve().parents[1] / "dist"
        if (repository_dist.is_symlink() or destination.parent.resolve() != repository_dist.resolve()
                or alias.parent != destination.parent or alias.name != LEGACY_NAME):
            raise ValueError("The compatibility alias is allowed only at this repository's old dist App path")
    descriptor = os.open(destination.parent / ".pocket3-local-install.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError("The install lock is not a regular file")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        preserved = install(source, destination)
        if alias is not None:
            preserved += ensure_legacy_alias(destination, alias)
        print(json.dumps({"installed": str(destination), "legacyAlias": str(alias) if alias else None,
                          "preservedPaths": [str(path) for path in preserved]}, ensure_ascii=False))
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    main()
