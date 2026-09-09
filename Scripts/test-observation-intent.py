#!/usr/bin/env python3
"""Exercise the packaged CLI's intent boundary against private fake IPC.

No App, model, camera or hardware service is contacted. The fake endpoint only
echoes requests; backend tool isolation is covered by Swift stage tests.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path(__file__).resolve().parents[1] /
                        "dist/Pocket 3 Controller.app/Contents/MacOS/pocket3")
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="p3-intent-", dir="/tmp") as temporary:
        root = Path(temporary)
        token = uuid.uuid4().hex
        credential = root / "connection-token"
        credential.write_text(token)
        credential.chmod(0o600)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(root / "bridge.sock"))
        (root / "bridge.sock").chmod(0o600)
        listener.listen(4)
        listener.settimeout(0.1)
        done = threading.Event()
        received, failures = [], []

        def serve():
            while not done.is_set():
                try:
                    connection, _ = listener.accept()
                except socket.timeout:
                    continue
                with connection:
                    try:
                        connection.settimeout(3)
                        with connection.makefile("rb") as stream:
                            request = json.loads(stream.readline(16384))
                        assert request["token"] == token and request["version"] == 1
                        assert request["operation"] == "ask"
                        received.append(request)
                        reply = {"version": 1, "id": request["id"], "result": request["arguments"]}
                        connection.sendall((json.dumps(reply) + "\n").encode())
                    except Exception as error:
                        failures.append(str(error))

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        environment = dict(os.environ, POCKET3_BRIDGE_DIRECTORY=str(root))

        def call(arguments):
            return subprocess.run([str(binary), *arguments], env=environment,
                                  capture_output=True, text=True, timeout=5)

        try:
            for intent in [None, "observe", "assistFraming"]:
                command = ["ask", "--question", "Do not move. Describe the image."]
                if intent is not None:
                    command += ["--intent", intent]
                result = call(command)
                assert result.returncode == 0, result.stderr
                payload = json.loads(result.stdout)
                assert payload.get("intent") == intent
                assert payload["question"] == command[2]
            valid_requests = len(received)
            for command in [
                ["ask", "--intent"], ["ask", "--intent", "unknown"],
                ["ask", "--intent", "--question", "Move"],
                ["evaluate-image", "--intent", "assistFraming"],
                ["evaluate-grounding", "--intent", "assistFraming"],
                ["status", "--intent", "observe"],
                ["ask", "--intent", "observe", "--intent", "assistFraming"],
            ]:
                result = call(command)
                assert result.returncode != 0 and json.loads(result.stderr)["code"] == "invalid_intent", result
            assert valid_requests == 3 and len(received) == valid_requests and not failures, failures
            print("Observation intent CLI: 3 forwarding cases and 7 pre-IPC rejections passed; no App or hardware.")
        finally:
            done.set()
            thread.join(timeout=4)
            listener.close()
            assert not thread.is_alive(), "Fake IPC did not terminate"


if __name__ == "__main__":
    main()
