#!/usr/bin/env python3
"""Prepare a stable, project-owned signing identity without changing certificate trust."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
DIRECTORY = PROJECT / ".local-signing"
KEYCHAIN = DIRECTORY / "Pocket3Development.keychain-db"
PASSWORD = DIRECTORY / "keychain-password"
CERTIFICATE = DIRECTORY / "certificate.pem"  # Public certificate only.
METADATA = DIRECTORY / "identity.json"


class SigningError(Exception):
    pass


class Commands:
    def __init__(self):
        self.secrets = []

    def run(self, label, arguments, *, environment=None):
        try:
            result = subprocess.run(arguments, capture_output=True, text=True,
                                    timeout=45, env=environment)
        except subprocess.TimeoutExpired:
            # TimeoutExpired includes the command arguments, possibly a password.
            raise SigningError(f"{label} timed out; no signing identity was replaced.") from None
        except OSError as error:
            raise SigningError(f"{label} could not run: {error.strerror}") from None
        if result.returncode:
            detail = result.stderr.strip()[-1500:]
            for secret in self.secrets:
                detail = detail.replace(secret, "[redacted]")
            raise SigningError(f"{label} failed (exit {result.returncode}): {detail}")
        return result.stdout.strip()

    def keychain_state(self):
        search = shlex.split(self.run("Read keychain search list",
            ["/usr/bin/security", "list-keychains", "-d", "user"]))
        default = self.run("Read default keychain",
            ["/usr/bin/security", "default-keychain", "-d", "user"])
        return search, default


def protected_file(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_uid != os.getuid():
        raise SigningError(f"Expected a regular project-owned file: {path.name}")
    path.chmod(0o600)


def write_private(path, contents):
    # Replacing metadata is atomic; a symlink is never followed.
    with tempfile.NamedTemporaryFile(dir=DIRECTORY, delete=False) as temporary:
        temporary.write(contents)
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    try:
        temporary_path.chmod(0o600)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def fingerprint(commands):
    value = commands.run("Read public certificate fingerprint", ["/usr/bin/openssl", "x509",
        "-in", str(CERTIFICATE), "-noout", "-fingerprint", "-sha1"])
    identity = value.split("=")[-1].replace(":", "").upper()
    if len(identity) != 40 or any(c not in "0123456789ABCDEF" for c in identity):
        raise SigningError("The public signing certificate has an invalid fingerprint.")
    return identity


def preserve_search_list(commands, original):
    search, default = commands.keychain_state()
    # On this Mac create-keychain with an absolute path leaves the search list
    # alone. Account for systems that append it, without leaving that change.
    if search != original[0]:
        if [path for path in search if path != str(KEYCHAIN)] != original[0]:
            raise SigningError("The keychain search list changed independently; it was left untouched and signing stopped.")
        commands.run("Restore unchanged keychain search list",
            ["/usr/bin/security", "list-keychains", "-d", "user", "-s", *original[0]])
    if default != original[1]:
        raise SigningError("The default keychain changed unexpectedly; signing stopped.")
    if commands.keychain_state() != original:
        raise SigningError("Could not preserve the original keychain configuration.")


def prepare_locked(commands):
    original = commands.keychain_state()
    created = False
    try:
        if METADATA.exists():
            for path in [METADATA, PASSWORD, CERTIFICATE, KEYCHAIN]:
                protected_file(path)
            metadata = json.loads(METADATA.read_text())
            if not isinstance(metadata, dict) or metadata.get("version") != 1 or metadata.get("kind") != "local_development":
                raise SigningError("Unsupported local signing metadata; existing identity was retained.")
            password = PASSWORD.read_text()
            if not password or "\n" in password:
                raise SigningError("Invalid dedicated keychain password file.")
            commands.secrets.append(password)
            identity = fingerprint(commands)
            if identity != metadata.get("identity"):
                raise SigningError("Certificate and metadata disagree; existing identity was retained.")
        else:
            if any(path.exists() or path.is_symlink() for path in [PASSWORD, CERTIFICATE, KEYCHAIN]):
                raise SigningError("Local signing setup is incomplete. Preserve .local-signing and repair it; do not regenerate the identity automatically.")
            password = secrets.token_urlsafe(36)
            commands.secrets.append(password)
            name = "Pocket 3 MCP Local Development " + secrets.token_hex(4)
            with tempfile.TemporaryDirectory(prefix="prepare-", dir=DIRECTORY) as temporary:
                work = Path(temporary)
                config, key, cert, p12 = [work / name for name in ["certificate.cnf", "private-key.pem", "certificate.pem", "identity.p12"]]
                config.write_text("[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=code_signing\n"
                    f"[subject]\nCN={name}\n[code_signing]\nbasicConstraints=critical,CA:FALSE\n"
                    "keyUsage=critical,digitalSignature\nextendedKeyUsage=codeSigning\nsubjectKeyIdentifier=hash\n")
                commands.run("Generate project code-signing certificate", ["/usr/bin/openssl", "req",
                    "-new", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                    "-config", str(config), "-keyout", str(key), "-out", str(cert)])
                protected_file(key)
                transfer_password = secrets.token_hex(24)
                commands.secrets.append(transfer_password)
                commands.run("Prepare temporary certificate transfer", ["/usr/bin/openssl", "pkcs12",
                    "-export", "-inkey", str(key), "-in", str(cert), "-out", str(p12),
                    "-macalg", "sha1", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES",
                    "-passout", "env:POCKET3_SIGNING_TRANSFER_PASSWORD"],
                    environment={**os.environ, "POCKET3_SIGNING_TRANSFER_PASSWORD": transfer_password})
                protected_file(p12)
                commands.run("Create project keychain", ["/usr/bin/security", "create-keychain",
                    "-p", password, str(KEYCHAIN)])
                created = True
                preserve_search_list(commands, original)
                protected_file(KEYCHAIN)
                # Keep recovery material in the protected project directory.
                # Only the keychain retains the private key after import.
                write_private(PASSWORD, password.encode())
                write_private(CERTIFICATE, cert.read_bytes())
                commands.run("Import project identity", ["/usr/bin/security", "import", str(p12),
                    "-k", str(KEYCHAIN), "-P", transfer_password, "-T", "/usr/bin/codesign"])
            identity = fingerprint(commands)
            metadata = {"version": 1, "kind": "local_development", "identity": identity,
                        "name": name, "keychainFile": KEYCHAIN.name}

        commands.run("Check signing certificate lifetime", ["/usr/bin/openssl", "x509",
            "-in", str(CERTIFICATE), "-noout", "-checkend", "0"])
        commands.run("Unlock project keychain", ["/usr/bin/security", "unlock-keychain",
            "-p", password, str(KEYCHAIN)])
        # Self-signed identities may be listed as NOT_TRUSTED while codesign
        # still accepts them with an explicit fingerprint and keychain. Using
        # find-identity -v here would incorrectly reject this working setup.
        identities = commands.run("Find project identity", ["/usr/bin/security", "find-identity",
            "-p", "codesigning", str(KEYCHAIN)])
        if identity not in identities.upper():
            raise SigningError("The project keychain does not contain the expected private signing identity.")
        if created:
            write_private(METADATA, (json.dumps(metadata, indent=2) + "\n").encode())
        for path in [METADATA, PASSWORD, CERTIFICATE, KEYCHAIN]:
            protected_file(path)
        return {"identity": identity, "keychain": str(KEYCHAIN), "kind": "local_development",
                "created": created, "searchListUnchanged": True, "defaultKeychainUnchanged": True}
    finally:
        preserve_search_list(commands, original)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true", required=True,
                        help="Create once or reuse the protected local identity; output public JSON only")
    parser.parse_args()
    os.umask(0o077)
    try:
        if DIRECTORY.is_symlink():
            raise SigningError(".local-signing must not be a symlink.")
        DIRECTORY.mkdir(mode=0o700, exist_ok=True)
        if not DIRECTORY.is_dir() or DIRECTORY.stat().st_uid != os.getuid():
            raise SigningError(".local-signing must be a directory owned by the current user.")
        DIRECTORY.chmod(0o700)
        lock = DIRECTORY / ".prepare.lock"
        if lock.is_symlink():
            raise SigningError("Local signing lock must not be a symlink.")
        with lock.open("a") as stream:
            lock.chmod(0o600)
            fcntl.flock(stream, fcntl.LOCK_EX)
            result = prepare_locked(Commands())
        print(json.dumps(result))
    except (SigningError, OSError, ValueError) as error:
        print(f"Local signing: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
