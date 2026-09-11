#!/usr/bin/env python3
"""Exercise the packaged stdio MCP server with a real JSON-RPC client."""
import argparse
import base64
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import tempfile
import threading
import time
import uuid

p = argparse.ArgumentParser()
p.add_argument("--binary", default="dist/Pocket 3 Controller.app/Contents/MacOS/pocket3")
p.add_argument("--output", default="artifacts/mcp-smoke")
p.add_argument("--offline", action="store_true")
a = p.parse_args()
out = Path(a.output); out.mkdir(parents=True, exist_ok=True)
(out / "result.json").write_text(json.dumps({"passed": False, "status": "running", "offline": a.offline}))

class OfflineBridge:
    """Private IPC fixture: never calls an App or camera; counts actual forwards."""
    def __init__(self):
        self.directory = tempfile.TemporaryDirectory(prefix="p3-mcp-contract-", dir="/tmp")
        self.token = uuid.uuid4().hex
        token_path = Path(self.directory.name) / "connection-token"
        token_path.write_text(self.token); token_path.chmod(0o600)
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(Path(self.directory.name) / "bridge.sock"))
        self.listener.listen(8); self.listener.settimeout(0.1)
        self.stopping = threading.Event(); self.lock = threading.Lock()
        self.requests = []; self.failures = []
        self.thread = threading.Thread(target=self.run, daemon=True); self.thread.start()

    def run(self):
        while not self.stopping.is_set():
            try: connection, _ = self.listener.accept()
            except socket.timeout: continue
            except OSError: return
            with connection:
                connection.settimeout(2)
                try:
                    with connection.makefile("rb") as stream:
                        raw = stream.readline(16385)
                    assert len(raw) <= 16384 and raw.endswith(b"\n")
                    request = json.loads(raw)
                    assert request["token"] == self.token and request["version"] == 1
                    assert request.get("source") == "mcp"
                    operation = request["operation"]
                    with self.lock: self.requests.append({"operation": operation, "arguments": request["arguments"]})
                    reply = {"id": request["id"], "version": 1}
                    if operation == "status": reply["result"] = {"phase": "idle", "simulation": True}
                    elif operation == "stop": reply["result"] = {"accepted": True, "completed": True, "simulation": True}
                    elif operation in {"snapshot", "move"}:
                        reply["error"] = {"code": "camera_not_ready", "message": "Offline fixture has no camera", "retryable": False}
                    else:
                        reply["error"] = {"code": "unexpected_forward", "message": "Unexpected IPC operation", "retryable": False}
                    connection.sendall((json.dumps(reply) + "\n").encode())
                except Exception as error:
                    with self.lock: self.failures.append(type(error).__name__)

    def snapshot(self):
        with self.lock: return list(self.requests), list(self.failures)

    def close(self):
        self.stopping.set(); self.listener.close(); self.thread.join(timeout=3)
        self.directory.cleanup()

offline_bridge = OfflineBridge() if a.offline else None
err = (out / "stderr.log").open("w")
environment = dict(os.environ)
if offline_bridge: environment["POCKET3_BRIDGE_DIRECTORY"] = offline_bridge.directory.name
proc = subprocess.Popen([a.binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, env=environment)
selector = selectors.DefaultSelector(); selector.register(proc.stdout, selectors.EVENT_READ)
buffer = bytearray()
def send(payload):
    proc.stdin.write((json.dumps(payload) + "\n").encode()); proc.stdin.flush()
def response(request_id):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        while b"\n" in buffer:
            line, _, tail = buffer.partition(b"\n"); buffer[:] = tail
            message = json.loads(line)
            if message.get("id") == request_id:
                if "error" in message: raise AssertionError(message)
                return message["result"]
        if selector.select(timeout=1):
            chunk = proc.stdout.read1(65536)
            if not chunk: raise AssertionError("MCP server exited before response")
            buffer.extend(chunk)
    raise TimeoutError(f"MCP response {request_id}")

def error_code(result):
    assert result.get("isError") is True, result
    text = next(item["text"] for item in result["content"] if item["type"] == "text")
    return json.loads(text)["code"]

try:
    send({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"Pocket3IntegrationTest","version":"1"}}})
    init = response(1)
    send({"jsonrpc":"2.0","method":"notifications/initialized"})
    send({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
    listing = response(2)
    names = {t["name"] for t in listing["tools"]}
    assert names == {"camera_status", "camera_format_inventory", "camera_body_status", "camera_connect",
                     "camera_pause", "camera_compare_frames", "camera_focus_status", "camera_roll_status",
                     "capture_frame", "move_gimbal", "stop_gimbal", "camera_zoom_status", "camera_set_zoom"}, names
    zoom_schema = next(t["inputSchema"] for t in listing["tools"] if t["name"] == "camera_set_zoom")
    assert set(zoom_schema["required"]) == {"rawValue", "expectedSessionID"}, zoom_schema
    assert zoom_schema["properties"]["rawValue"]["type"] == "integer", zoom_schema
    assert zoom_schema["additionalProperties"] is False, zoom_schema
    roll_schema = next(t["inputSchema"] for t in listing["tools"] if t["name"] == "camera_roll_status")
    assert roll_schema["additionalProperties"] is False and "rawValue" not in roll_schema["properties"], roll_schema
    send({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"camera_status","arguments":{}}})
    status = response(3)
    assert not status.get("isError"), status
    send({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"capture_frame","arguments":{"maxDimension":1280}}})
    capture = response(4)
    image = b""
    if a.offline:
        assert error_code(capture) == "camera_not_ready", capture
        assert not any(x["type"] == "image" for x in capture["content"])
    else:
        assert not capture.get("isError"), capture
        images = [x for x in capture["content"] if x["type"] == "image"]
        assert len(images) == 1
        image = base64.b64decode(images[0]["data"], validate=True)
        assert image.startswith(b"\xff\xd8") and len(image) > 1000
        (out / "frame.jpg").write_bytes(image)
    forwards_before_invalid = offline_bridge.snapshot()[0] if offline_bridge else None
    send({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"capture_frame","arguments":{"maxDimension":1e100}}})
    invalid = response(5)
    assert error_code(invalid) == "invalid_size", invalid
    # These malformed zoom calls must fail at the MCP argument boundary before
    # reaching IPC. This smoke test never submits a valid zoom/motion request.
    invalid_zoom = [
        {"rawValue": 100.5, "expectedSessionID": "invalid-smoke-session"},
        {"rawValue": 100},
        {"rawValue": 100, "expectedSessionID": "invalid-smoke-session", "factor": 2},
    ]
    for request_id, arguments in enumerate(invalid_zoom, start=6):
        send({"jsonrpc":"2.0","id":request_id,"method":"tools/call","params":{"name":"camera_set_zoom","arguments":arguments}})
        rejected = response(request_id)
        assert error_code(rejected) in {"invalid_zoom_value", "invalid_zoom_arguments", "session_required"}, rejected
    invalid_camera = [
        ("camera_status", {"unknown": True}, "invalid_camera_arguments"),
        ("stop_gimbal", {"direction": "left"}, "invalid_camera_arguments"),
        *[("capture_frame", {"maxDimension": size}, "invalid_size") for size in ["1280", True, None, 319, 3841, 320.5]],
        ("capture_frame", {"maxDimension": 1280, "origin": "manual"}, "invalid_camera_arguments"),
        ("move_gimbal", {}, "invalid_target"),
        *[("move_gimbal", {"direction": direction}, "invalid_target") for direction in ["LEFT", "absolute", True, None]],
        ("move_gimbal", {"direction": "left", "panDegrees": None}, "invalid_target"),
        ("move_gimbal", {"direction": "up", "tiltDegrees": 2}, "invalid_target"),
        *[("move_gimbal", {"panDegrees": angle}, "invalid_target") for angle in ["0", True, None, 1e100]],
        ("move_gimbal", {"panDegrees": 0, "tiltDegrees": None}, "invalid_target"),
        ("move_gimbal", {"direction": "left", "origin": "manual"}, "invalid_camera_arguments"),
    ]
    if not offline_bridge:
        # A regression in argument validation must never turn a malformed
        # movement/stop test into an actual command on the user's camera.
        invalid_camera = [case for case in invalid_camera if case[0] in {"camera_status", "capture_frame"}]
    for request_id, (name, arguments, expected_code) in enumerate(invalid_camera, start=20):
        send({"jsonrpc":"2.0","id":request_id,"method":"tools/call","params":{"name":name,"arguments":arguments}})
        rejected = response(request_id)
        assert error_code(rejected) == expected_code, (name, arguments, rejected)
    if offline_bridge:
        forwarded, failures = offline_bridge.snapshot()
        assert not failures, failures
        assert forwarded == forwards_before_invalid, "Malformed arguments reached IPC"
        # Valid requests must reach the fixture and retain the real service's
        # not-ready error; it must never count as an argument rejection.
        for request_id, name, arguments in [
            (80, "capture_frame", {}), (81, "move_gimbal", {"direction": "left"}),
            (82, "move_gimbal", {"panDegrees": 0, "tiltDegrees": -1}),
        ]:
            send({"jsonrpc":"2.0","id":request_id,"method":"tools/call","params":{"name":name,"arguments":arguments}})
            assert error_code(response(request_id)) == "camera_not_ready"
        send({"jsonrpc":"2.0","id":83,"method":"tools/call","params":{"name":"stop_gimbal","arguments":{}}})
        assert not response(83).get("isError")
        forwarded, failures = offline_bridge.snapshot()
        assert not failures and [entry["operation"] for entry in forwarded] == ["status", "snapshot", "snapshot", "move", "move", "stop"], (forwarded, failures)
    report = {"passed":True,"status":"complete","offline":a.offline,"isolatedIPCFixture":bool(offline_bridge),"protocol":init["protocolVersion"],"tools":sorted(names),"frame":capture.get("structuredContent"),"imageBytes":len(image),"invalidSizeRejected":True,"invalidZoomArgumentsRejected":len(invalid_zoom),"invalidCameraArgumentsRejected":len(invalid_camera),"malformedCallsForwarded":0 if offline_bridge else None,"validNotReadyForwardingVerified":bool(offline_bridge)}
    (out / "result.json").write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps(report,ensure_ascii=False,indent=2))
except BaseException as error:
    (out / "result.json").write_text(json.dumps({"passed":False,"status":"failed","offline":a.offline,"failureType":type(error).__name__},indent=2))
    raise
finally:
    proc.stdin.close()
    try: proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.terminate();proc.wait(timeout=5)
    err.close()
    selector.close()
    if offline_bridge: offline_bridge.close()
