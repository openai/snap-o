import base64
import contextlib
import gzip
import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import select
import socket
import socketserver
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock


REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "cli" / "snapo"
LOADER = importlib.machinery.SourceFileLoader("snapo_cli", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
snapo = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(snapo)


REQUEST_SECRET = "request-secret-must-not-print"
COOKIE_SECRET = "cookie-secret-must-not-print"
RESPONSE_SECRET = "response-secret-must-not-print"


def request_event():
    return {
        "method": "Network.requestWillBeSent",
        "params": {
            "requestId": "request-1",
            "request": {
                "method": "POST",
                "url": "https://example.test/api",
                "hasPostData": True,
                "postDataEncoding": "utf8",
                "headers": {
                    "Authorization": REQUEST_SECRET,
                    "Cookie": COOKIE_SECRET,
                    "Accept": "application/json",
                },
            },
        },
    }


def response_event():
    return {
        "method": "Network.responseReceived",
        "params": {
            "requestId": "request-1",
            "response": {
                "status": 200,
                "url": "https://example.test/api",
                "headers": {
                    "Set-Cookie": RESPONSE_SECRET,
                    "Content-Type": "application/json",
                },
            },
        },
    }


class WireServer:
    def __init__(self, handler, adb_handshake=False, bodies=None, history=(), watermark=0, complete_history=True):
        self.handler = handler
        self.history = history
        self.watermark = watermark
        self.complete_history = complete_history
        self.http_requests = []
        self.peers = []
        self.adb_handshake = adb_handshake
        self.bodies = bodies or {}
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(16)
        self.port = self.listener.getsockname()[1]
        self.received = []
        self.failure = None
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, error_type, error, traceback):
        if self.thread.is_alive():
            self.stopping.set()
            with socket.create_connection(("127.0.0.1", self.port), timeout=1):
                pass
        self.thread.join(timeout=3)
        for peer in self.peers:
            peer.join(timeout=3)
        self.listener.close()
        if error_type is not None:
            return
        if self.failure:
            raise self.failure
        if self.thread.is_alive():
            raise AssertionError("wire server did not stop")

    def run(self):
        while not self.stopping.is_set():
            connection, _ = self.listener.accept()
            if self.stopping.is_set():
                connection.close()
                break
            peer = threading.Thread(target=self.serve, args=(connection,), daemon=True)
            self.peers.append(peer)
            peer.start()

    def serve(self, connection):
        try:
            with connection:
                connection.settimeout(3)
                stream = connection.makefile("rwb", buffering=0)
                commands = []
                if self.adb_handshake:
                    for _ in range(2):
                        length = int(stream.read(4), 16)
                        commands.append(stream.read(length).decode("utf-8"))
                        stream.write(b"OKAY")
                request = stream.readline()
                head = request
                while not head.endswith(b"\r\n\r\n"):
                    line = stream.readline()
                    if not line:
                        raise EOFError("HTTP headers ended early")
                    head += line
                path = request.decode("ascii").split()[1]
                self.received.extend(commands)
                if path == "/network" and b"Accept: application/x-ndjson\r\n" in head:
                    self.http_requests.append(path)
                    stream.write((f"HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\nSnapO-Sequence: {self.watermark}\r\n\r\n").encode())
                    for message in self.history:
                        body = json.dumps(message).encode() + b"\n"
                        stream.write(f"{len(body):x}\r\n".encode() + body + b"\r\n")
                    if self.complete_history:
                        stream.write(b"0\r\n\r\n")
                elif path == "/network" and b"Accept: text/event-stream\r\n" in head:
                    self.http_requests.append(path)
                    stream.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
                    self.handler(stream, self.received)
                    # Keep the stream alive until the client closes it.
                    stream.read(1)
                elif path.startswith("/network/requests/"):
                    self.http_requests.append(path)
                    kind = path.split("?")[0].rsplit("/", 1)[-1]
                    body = self.bodies.get(kind)
                    status = "200 OK" if body is not None else "404 Not Found"
                    payload = json.dumps(body if body is not None else {"error": "No body captured"}).encode()
                    stream.write(f"HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n".encode() + payload)
                else:
                    raise AssertionError(f"Unexpected HTTP path: {path}")
        except Exception as error:
            if not self.stopping.is_set():
                self.failure = error


def write_message(stream, value):
    sequence = value.get("snapoSequence", 1) if isinstance(value, dict) else 1
    if isinstance(value, dict):
        value = {**value, "snapoSequence": sequence}
    payload = f"id: {sequence}\ndata: ".encode() + json.dumps(value, separators=(",", ":")).encode() + b"\n\n"
    stream.write(f"{len(payload):x}\r\n".encode() + payload + b"\r\n")


def open_session(port):
    factory = lambda timeout=5: snapo.LocalAbstractSocket(port=port, timeout=timeout)
    return snapo.Session(factory)


class SSETests(unittest.TestCase):
    def decoder(self, payload):
        decoder = object.__new__(snapo.NetworkSSE)
        decoder.pending = bytearray()
        decoder.response_lock = threading.Lock()
        decoder.response = mock.Mock()
        chunks = iter(bytes([byte]) for byte in payload)
        decoder.response.read1.side_effect = lambda _: next(chunks, b"")
        return decoder

    def test_comments_crlf_multiline_and_split_utf8(self):
        event = self.decoder(': heartbeat\r\nid: 9\r\nevent: ready\r\ndata: {\r\ndata: "label":"🙂"}\r\n\r\n'.encode()).read_event()
        self.assertEqual(event["data"], {"label": "🙂"})
        self.assertEqual(event["id"], "9")
        self.assertEqual(event["event"], "ready")

    def test_partial_and_invalid_events_fail(self):
        for payload in (b'data: {}\n', b'data: "\xff"\n\n', b'data: nope\n\n'):
            with self.subTest(payload=payload), self.assertRaises(snapo.SnapOError):
                self.decoder(payload).read_event()

    def test_event_size_is_bounded(self):
        with mock.patch.object(snapo, "MAX_RECORD_BYTES", 4):
            with self.assertRaisesRegex(snapo.SnapOError, "too large"):
                self.decoder(b'data: 12345\n\n').read_event()


def process_manifest():
    return {
        "version": 1, "pid": 42, "processName": "com.example",
        "processIdentity": "boot:42:1",
        "app": {
            "name": "Example", "packageName": "com.example",
            "inspectors": [
                {"id": "network", "protocolVersion": 3},
                {"id": "tweaks", "protocolVersion": 7},
            ],
        },
    }


class FakeADB:
    has_explicit_endpoint = False

    def __init__(self, forward_port=27185):
        self.forward_port = forward_port
        self.calls = []
        self.metadata_calls = []
        self.manifest = process_manifest()

    def devices(self):
        return ["emulator-5554"]

    def sockets(self, serial, prefix=snapo.SOCKET_PREFIX):
        return ["snapo_network_42"]

    def tool_metadata(self, serial, socket_names):
        self.metadata_calls.append((serial, socket_names))
        return [{**self.manifest, "pid": int(name.rsplit("_", 1)[1])} for name in socket_names]

    def command(self, *arguments, serial=None):
        self.calls.append((serial, arguments))
        if arguments[:2] == ("forward", "tcp:0"):
            return str(self.forward_port)
        return ""


class WireServerTests(unittest.TestCase):
    def test_idle_listener_stops_without_a_client_connection(self):
        with WireServer(lambda stream, received: self.fail("handler should not run")) as server:
            pass

        self.assertFalse(server.thread.is_alive())

    def test_idle_listener_preserves_an_exception_from_the_context(self):
        with self.assertRaisesRegex(RuntimeError, "original test failure"):
            with WireServer(lambda stream, received: self.fail("handler should not run")):
                raise RuntimeError("original test failure")


class FakeTweakADB(FakeADB):
    def __init__(self, sockets=None, devices=None, forward_port=27185):
        super().__init__(forward_port=forward_port)
        self.manifest["app"].update(name="Snap-O Tweaks Demo", packageName="com.example.tweaks")
        self.available_devices = devices or ["emulator-5554"]
        self.available_sockets = sockets or {"emulator-5554": ["snapo_tweaks_42"]}

    def devices(self):
        return self.available_devices

    def sockets(self, serial, prefix=snapo.SOCKET_PREFIX):
        if prefix != snapo.TWEAK_SOCKET_PREFIX:
            return super().sockets(serial, prefix)
        value = self.available_sockets.get(serial, [])
        if isinstance(value, Exception):
            raise value
        return value


def tweak_descriptors():
    return [
        {
            "name": "Typography/Font size",
            "type": "int",
            "default": 16,
            "value": 16,
            "min": -8,
            "max": 48,
            "step": 2,
        },
        {
            "name": "Motion/Damping ratio",
            "type": "float",
            "default": 0.5,
            "value": 0.5,
            "min": -1.0,
            "max": 1.0,
            "step": 0.1,
        },
        {"name": "Motion/Enabled", "type": "boolean", "default": True, "value": True},
        {
            "name": "Palette/Accent color",
            "type": "color",
            "default": "#5468FF",
            "value": "#5468FF",
        },
        {"name": "Preview/Text value", "type": "string", "default": "true", "value": "true"},
        {
            "name": "Appearance/Theme",
            "type": "enum",
            "default": "System",
            "value": "System",
            "options": ["System", "Light", "Dark"],
        },
    ]


class TweakHTTPServer:
    def __init__(
        self,
        descriptors=None,
        error=None,
        stream_events=None,
        adjusted_descriptors=None,
        update_errors=None,
    ):
        self.descriptors = json.loads(json.dumps(descriptors or tweak_descriptors()))
        self.adjusted_descriptors = self.descriptors if adjusted_descriptors is None else adjusted_descriptors
        self.error = error
        self.update_errors = update_errors or {}
        self.stream_events = stream_events
        self.requests = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                owner.requests.append(("GET", self.path, None))
                if self.path == "/tweaks":
                    self.send_json(200, {"tweaks": owner.descriptors})
                elif self.path == "/tweaks?include=adjusted":
                    self.send_json(200, {"tweaks": owner.adjusted_descriptors})
                elif self.path == "/tweaks/events":
                    events = owner.stream_events or [
                        ": keep-alive\n\n",
                        "event: ignored\ndata: {\"unexpected\":true}\n\n",
                        "event: tweaks\ndata: " + json.dumps({"tweaks": owner.descriptors}) + "\n\n",
                    ]
                    body = "".join(events).encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(body)
                    self.wfile.flush()
                else:
                    self.send_json(404, {"error": f"Unknown endpoint: {self.path}"})

            def do_PATCH(self):
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                owner.requests.append(("PATCH", self.path, payload))
                if owner.error is not None:
                    status, message = owner.error
                    self.send_json(status, {"error": message})
                    return

                descriptors = {item["name"]: item for item in owner.descriptors}
                if set(payload) != {"values"} or not isinstance(payload["values"], dict):
                    self.send_json(400, {"error": "Invalid tweak mutation request"})
                    return

                updates = []
                errors = []
                for name, value in payload["values"].items():
                    if name not in descriptors:
                        message = f"Unknown tweak: {name}"
                        errors.append({"name": name, "error": message})
                        continue
                    if name in owner.update_errors:
                        message = owner.update_errors[name]
                        errors.append({"name": name, "error": message})
                        continue
                    if value is None:
                        value = descriptors[name]["default"]
                    if descriptors[name]["type"] == "color":
                        value = value.upper()
                    descriptors[name]["value"] = value
                    modified = value != descriptors[name]["default"]
                    update = {"name": name, "value": value}
                    if modified:
                        descriptors[name]["modified"] = True
                        update["modified"] = True
                    else:
                        descriptors[name].pop("modified", None)
                    updates.append(update)
                response = {"tweaks": updates}
                if errors:
                    response["errors"] = errors
                self.send_json(200, response)

            def do_POST(self):
                length = int(self.headers.get("Content-Length", "0"))
                payload = json.loads(self.rfile.read(length).decode("utf-8"))
                owner.requests.append(("POST", self.path, payload))
                if owner.error is not None:
                    status, message = owner.error
                    self.send_json(status, {"error": message})
                    return
                if self.path != "/tweaks/action":
                    self.send_json(404, {"error": f"Unknown endpoint: {self.path}"})
                    return

                actions = [
                    item
                    for item in owner.descriptors
                    if item["name"] == payload.get("name") and item["type"] == "action"
                ]
                if not actions:
                    self.send_json(404, {"error": f"Unknown action: {payload.get('name')}"})
                    return
                if len(actions) != 1 or actions[0].get("conflicted") is True:
                    self.send_json(409, {"error": f"Conflicting action registrations: {payload.get('name')}"})
                    return
                self.send_json(200, {"name": payload["name"]})

            def send_json(self, status, payload):
                body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format, *arguments):
                return None

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, error_type, error, traceback):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        if self.thread.is_alive():
            raise AssertionError("tweak HTTP server did not stop")


class TweakSmartSocketServer:
    def __init__(self, payload):
        self.payload = payload
        self.received = []
        owner = self

        class Handler(socketserver.BaseRequestHandler):
            def handle(self):
                stream = self.request.makefile("rwb", buffering=0)
                for _ in range(2):
                    size = int(stream.read(4), 16)
                    owner.received.append(stream.read(size).decode("utf-8"))
                    stream.write(b"OKAY")

                request_line = stream.readline().decode("utf-8").rstrip()
                owner.received.append(request_line)
                while stream.readline().strip():
                    pass

                body = json.dumps(owner.payload).encode("utf-8")
                response = (
                    b"HTTP/1.1 200 OK\r\n"
                    b"Content-Type: application/json\r\n"
                    + f"Content-Length: {len(body)}\r\n".encode("ascii")
                    + b"Connection: close\r\n\r\n"
                    + body
                )
                stream.write(response)

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, error_type, error, traceback):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        if self.thread.is_alive():
            raise AssertionError("tweak ADB smart-socket server did not stop")


class PluginPackagingTests(unittest.TestCase):
    def test_plugin_bundles_network_inspection_and_live_tweaks_skills(self):
        manifest = json.loads((REPOSITORY / ".codex-plugin" / "plugin.json").read_text(encoding="utf-8"))
        release_version = next(
            line.partition("=")[2].strip()
            for line in (REPOSITORY / "VERSION").read_text(encoding="utf-8").splitlines()
            if line.startswith("VERSION =")
        )

        self.assertEqual(manifest["name"], "snap-o")
        self.assertEqual(manifest["version"], release_version)
        skills_root = (REPOSITORY / manifest["skills"]).resolve()
        self.assertEqual(skills_root, REPOSITORY / "skills")
        self.assertEqual(SCRIPT.parent, REPOSITORY / "cli")
        self.assertTrue(SCRIPT.is_file())
        self.assertTrue(os.access(SCRIPT, os.X_OK))
        self.assertEqual(manifest["interface"]["displayName"], "Snap-O")
        self.assertEqual(manifest["interface"]["capabilities"], ["Read", "Write"])

        for name, display_name in (
            ("snap-o-network-inspector", "Snap-O Network Tool"),
            ("snap-o-tweaks", "Snap-O Tweaks"),
        ):
            with self.subTest(skill=name):
                skill_path = skills_root / name / "SKILL.md"
                agent_path = skills_root / name / "agents" / "openai.yaml"

                self.assertTrue(skill_path.is_file())
                skill_content = skill_path.read_text(encoding="utf-8")
                self.assertIn(f"\nname: {name}\n", skill_content)
                self.assertIn("../../cli/snapo", skill_content)
                self.assertEqual((skill_path.parent / "../../cli/snapo").resolve(), SCRIPT)
                self.assertTrue(agent_path.is_file())

                agent_metadata = agent_path.read_text(encoding="utf-8")
                self.assertIn("interface:\n", agent_metadata)
                self.assertIn(f'display_name: "{display_name}"', agent_metadata)
                self.assertIn("short_description:", agent_metadata)
                self.assertIn(f"${name}", agent_metadata)

    def test_tweaks_skill_reuses_shared_cli_and_bundles_protocol_references(self):
        skill_root = REPOSITORY / "skills" / "snap-o-tweaks"
        skill_content = (skill_root / "SKILL.md").read_text(encoding="utf-8")
        shared_cli = "../../cli/snapo"

        self.assertIn(shared_cli, skill_content)
        self.assertEqual((skill_root / shared_cli).resolve(), SCRIPT.resolve())
        self.assertTrue(SCRIPT.is_file())

        for name in ("protocol.md", "interaction-surfaces.md"):
            with self.subTest(reference=name):
                reference = skill_root / "references" / name
                self.assertTrue(reference.is_file())
                self.assertTrue(reference.read_text(encoding="utf-8").strip())
                self.assertIn(f"references/{name}", skill_content)

    def test_marketplace_exposes_the_repository_plugin(self):
        marketplace = json.loads(
            (REPOSITORY / ".agents" / "plugins" / "marketplace.json").read_text(encoding="utf-8")
        )
        self.assertEqual(marketplace["name"], "snap-o")
        self.assertEqual(len(marketplace["plugins"]), 1)

        plugin = marketplace["plugins"][0]
        self.assertEqual(plugin["name"], "snap-o")
        self.assertEqual(plugin["source"], {"source": "local", "path": "./"})
        self.assertEqual((REPOSITORY / plugin["source"]["path"]).resolve(), REPOSITORY)
        self.assertEqual(plugin["policy"]["installation"], "AVAILABLE")
        self.assertEqual(plugin["policy"]["authentication"], "ON_INSTALL")

class DiscoveryTests(unittest.TestCase):
    def test_parses_devices_and_deduplicates_sockets(self):
        devices = snapo.parse_devices(
            """List of devices attached
emulator-5554 device product:sdk
phone offline transport_id:2
usb-phone device product:oriole
"""
        )
        sockets = snapo.parse_sockets(
            """Num RefCount Protocol Flags Type St Inode Path
1: 0 0 00010000 0001 01 1 @snapo_network_42
2: 0 0 00010000 0001 01 2 @unrelated
3: 0 0 00010000 0001 01 3 @snapo_network_7
4: 0 0 00010000 0001 01 4 @snapo_network_42
"""
        )
        self.assertEqual(devices, ["emulator-5554", "usb-phone"])
        self.assertEqual(sockets, ["snapo_network_42", "snapo_network_7"])

    def test_ignores_nonlisteners_and_invalid_socket_names(self):
        output = """1: 0 0 00010000 0001 01 1 @snapo_network_42
2: 0 0 00000000 0001 03 2 @snapo_network_43
3: 0 0 00010000 0001 01 3 @snapo_network_0
4: 0 0 00010000 0001 01 4 @snapo_network_invalid
5: 0 0 00010000 0001 01 5 @snapo_network_9999999999999
"""
        self.assertEqual(snapo.parse_sockets(output), ["snapo_network_42"])

    def test_preserves_snapo_device_selection(self):
        devices = ["emulator-5554", "usb-phone"]
        self.assertEqual(snapo.select_devices(devices, emulator=True), ["emulator-5554"])
        self.assertEqual(snapo.select_devices(devices, usb=True), ["usb-phone"])
        self.assertEqual(snapo.select_devices(devices, serial="usb-phone"), ["usb-phone"])
        with self.assertRaisesRegex(snapo.SnapOError, "not connected"):
            snapo.select_devices(devices, serial="missing")

    def test_chooses_qualified_socket(self):
        servers = [
            snapo.Server("emulator-5554", "snapo_network_42"),
            snapo.Server("usb-phone", "snapo_network_42"),
        ]
        self.assertEqual(
            snapo.choose_server(servers, "usb-phone/snapo_network_42"),
            servers[1],
        )
        with self.assertRaisesRegex(snapo.SnapOError, "multiple devices"):
            snapo.choose_server(servers, "snapo_network_42")

    def test_discovery_continues_after_one_device_becomes_unavailable(self):
        class PartiallyUnavailableADB:
            def devices(self):
                return ["disconnected-device", "emulator-5554"]

            def sockets(self, serial, prefix=snapo.SOCKET_PREFIX):
                if serial == "disconnected-device":
                    raise snapo.SnapOError("device disconnected")
                return ["snapo_network_42"]

        options = snapo.parser().parse_args(["network", "list"])
        servers = snapo.discover(PartiallyUnavailableADB(), options)
        self.assertEqual(servers, [snapo.Server("emulator-5554", "snapo_network_42")])


class TweakDiscoveryTests(unittest.TestCase):
    def test_server_pid_supports_both_network_and_tweak_socket_prefixes(self):
        self.assertEqual(snapo.Server("emulator-5554", "snapo_network_42").pid, 42)
        self.assertEqual(snapo.Server("emulator-5554", "snapo_tweaks_42").pid, 42)

    def test_parses_tweak_sockets_without_mixing_network_tools(self):
        output = """Num RefCount Protocol Flags Type St Inode Path
1: 0 0 00010000 0001 01 1 @snapo_network_42
2: 0 0 00010000 0001 01 2 @snapo_tweaks_93
3: 0 0 00010000 0001 01 3 @unrelated
4: 0 0 00010000 0001 01 4 @snapo_tweaks_7
5: 0 0 00010000 0001 01 5 @snapo_tweaks_93
6: 0 0 00010000 0001 01 6 @snapo_tweaks_invalid
"""
        self.assertEqual(
            snapo.parse_sockets(output, snapo.TWEAK_SOCKET_PREFIX),
            ["snapo_tweaks_7", "snapo_tweaks_93"],
        )
        self.assertEqual(snapo.parse_sockets(output), ["snapo_network_42"])

    def test_adb_tweak_socket_discovery_reads_device_unix_sockets(self):
        recorded = []

        def run(command, **kwargs):
            recorded.append(command)
            output = "1: 0 0 00010000 0001 01 1 @snapo_tweaks_42\n2: 0 0 00010000 0001 01 2 @snapo_network_9\n"
            return type("Result", (), {"returncode": 0, "stdout": output, "stderr": ""})()

        adb = snapo.ADB("/configured/adb", run=run)
        self.assertEqual(adb.sockets("emulator-5554", snapo.TWEAK_SOCKET_PREFIX), ["snapo_tweaks_42"])
        self.assertEqual(
            recorded,
            [["/configured/adb", "-s", "emulator-5554", "shell", "cat /proc/net/unix"]],
        )

    def test_discovers_tweaks_on_selected_devices_and_skips_unavailable_devices(self):
        adb = FakeTweakADB(
            devices=["disconnected-device", "emulator-5554", "usb-phone"],
            sockets={
                "disconnected-device": snapo.SnapOError("device disconnected"),
                "emulator-5554": ["snapo_tweaks_42"],
                "usb-phone": ["snapo_tweaks_8"],
            },
        )
        options = snapo.parser().parse_args(["tweaks", "apps"])
        self.assertEqual(
            snapo.discover(adb, options, snapo.TWEAK_SOCKET_PREFIX),
            [snapo.Server("emulator-5554", "snapo_tweaks_42"), snapo.Server("usb-phone", "snapo_tweaks_8")],
        )

        selected = snapo.parser().parse_args(["tweaks", "apps", "-s", "usb-phone"])
        self.assertEqual(
            snapo.discover(adb, selected, snapo.TWEAK_SOCKET_PREFIX),
            [snapo.Server("usb-phone", "snapo_tweaks_8")],
        )

    def test_parser_registers_every_tweak_command_and_shared_selectors(self):
        commands = {
            "apps": ["apps"],
            "list": ["list", "-n", "snapo_tweaks_42"],
            "get": ["get", "Typography/Font size", "-n", "snapo_tweaks_42"],
            "set": ["set", "Typography/Font size", "-2", "-n", "snapo_tweaks_42"],
            "action": ["action", "Preview/Refresh", "-n", "snapo_tweaks_42"],
            "reset": ["reset", "Typography/Font size", "-n", "snapo_tweaks_42"],
            "watch": ["watch", "--once", "-n", "snapo_tweaks_42"],
        }
        for name, arguments in commands.items():
            with self.subTest(command=name):
                command = ["tweaks", *arguments, "-s", "emulator-5554", "--adb", "/configured/adb"]
                if name not in {"set", "action", "reset"}:
                    command.append("--json")
                options = snapo.parser().parse_args(command)
                self.assertEqual(options.root_command, "tweaks")
                self.assertEqual(options.tweaks_command, name)
                self.assertEqual(options.serial, "emulator-5554")
                self.assertEqual(options.adb, "/configured/adb")
                if name not in {"set", "action", "reset"}:
                    self.assertTrue(options.json)

    def test_tweak_commands_preserve_remote_adb_endpoint_validation(self):
        commands = (
            ["tweaks", "apps"],
            ["tweaks", "list"],
            ["tweaks", "get", "Motion/Enabled"],
            ["tweaks", "set", "Motion/Enabled", "false"],
            ["tweaks", "action", "Preview/Refresh"],
            ["tweaks", "reset", "Motion/Enabled"],
            ["tweaks", "watch", "--once"],
        )
        for command in commands:
            with self.subTest(command=command[1]):
                options = snapo.parser().parse_args(
                    command + ["--adb-host", "adb.example.test", "--adb-port", "15037"]
                )
                self.assertEqual(options.adb_host, "adb.example.test")
                self.assertEqual(options.adb_port, 15037)

                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    with self.assertRaises(SystemExit):
                        snapo.parser().parse_args(command + ["--adb-host", "adb.example.test"])
                self.assertIn("--adb-host and --adb-port must be used together", errors.getvalue())

    def test_main_shows_tweaks_group_help_without_starting_adb(self):
        stdout = io.StringIO()
        with mock.patch.object(snapo, "resolve_adb", side_effect=AssertionError("adb should not start")):
            with contextlib.redirect_stdout(stdout):
                with self.assertRaises(SystemExit) as result:
                    snapo.main(["tweaks"])

        self.assertEqual(result.exception.code, 0)
        self.assertIn("apps", stdout.getvalue())
        self.assertIn("action", stdout.getvalue())
        self.assertIn("watch", stdout.getvalue())


class TweakValueTests(unittest.TestCase):
    def descriptor(self, name):
        return next(item for item in tweak_descriptors() if item["name"] == name)

    def test_integer_values_preserve_negative_numbers_and_reject_fractional_values(self):
        descriptor = self.descriptor("Typography/Font size")
        self.assertEqual(snapo.parse_tweak_value(descriptor, "-2"), -2)
        with self.assertRaises(snapo.SnapOError):
            snapo.parse_tweak_value(descriptor, "2.5")
        with self.assertRaises(snapo.SnapOError):
            snapo.parse_tweak_value(descriptor, "true")

    def test_float_values_preserve_negative_numbers_and_reject_nonfinite_numbers(self):
        descriptor = self.descriptor("Motion/Damping ratio")
        self.assertEqual(snapo.parse_tweak_value(descriptor, "-0.5"), -0.5)
        self.assertEqual(snapo.parse_tweak_value(descriptor, "1"), 1.0)
        for value in ("nan", "NaN", "inf", "-inf", "infinity"):
            with self.subTest(value=value):
                with self.assertRaises(snapo.SnapOError):
                    snapo.parse_tweak_value(descriptor, value)

    def test_boolean_values_are_typed_but_strings_remain_literal(self):
        boolean = self.descriptor("Motion/Enabled")
        self.assertIs(snapo.parse_tweak_value(boolean, "TRUE"), True)
        self.assertIs(snapo.parse_tweak_value(boolean, "false"), False)
        with self.assertRaises(snapo.SnapOError):
            snapo.parse_tweak_value(boolean, "maybe")

        string = self.descriptor("Preview/Text value")
        self.assertEqual(snapo.parse_tweak_value(string, "true"), "true")
        self.assertEqual(snapo.parse_tweak_value(string, "-0.5"), "-0.5")

    def test_colors_accept_rgb_or_rgba_and_reject_invalid_hex(self):
        descriptor = self.descriptor("Palette/Accent color")
        self.assertEqual(snapo.parse_tweak_value(descriptor, "#3b82f6").upper(), "#3B82F6")
        self.assertEqual(snapo.parse_tweak_value(descriptor, "#3B82F680").upper(), "#3B82F680")
        for value in ("3B82F6", "#FFF", "#3B82FG", "#123456789"):
            with self.subTest(value=value):
                with self.assertRaises(snapo.SnapOError):
                    snapo.parse_tweak_value(descriptor, value)

    def test_enums_accept_only_exact_declared_option_names(self):
        descriptor = self.descriptor("Appearance/Theme")

        self.assertEqual(snapo.parse_tweak_value(descriptor, "Dark"), "Dark")
        self.assertEqual(snapo.parse_tweak_value(descriptor, "System"), "System")

        for invalid in ("dark", "DARK", "Dark mode", "Unknown"):
            with self.subTest(value=invalid):
                with self.assertRaisesRegex(snapo.SnapOError, '"System", "Light", "Dark"'):
                    snapo.parse_tweak_value(descriptor, invalid)

    def test_enums_reject_malformed_option_descriptors(self):
        original = self.descriptor("Appearance/Theme")
        cases = (
            ({"options": None}, "non-empty option list"),
            ({"options": []}, "non-empty option list"),
            ({"options": [" "]}, "nonblank strings"),
            ({"options": [{"value": "System"}]}, "nonblank strings"),
            ({"options": ["System", "System"]}, "must be unique"),
            ({"value": "unknown"}, "the value must match"),
            ({"default": "unknown"}, "the default must match"),
        )

        for changes, detail in cases:
            with self.subTest(detail=detail):
                descriptor = json.loads(json.dumps(original))
                descriptor.update(changes)
                with self.assertRaisesRegex(snapo.SnapOError, detail):
                    snapo.tweak_descriptors({"tweaks": [descriptor]})


class ADBTests(unittest.TestCase):
    def test_repeated_shutdown_signals_allow_forward_cleanup(self):
        script = f'''
import runpy, signal, time
snapo = runpy.run_path({str(SCRIPT)!r})
signal.signal(signal.SIGINT, snapo["interrupted"])
signal.signal(signal.SIGTERM, snapo["interrupted"])
class Adb:
    def command(self, *args, **kwargs):
        if args[1] == "--remove":
            print("removing", flush=True)
            time.sleep(0.2)
            print("removed", flush=True)
        return "27185"
try:
    with snapo["Forward"](Adb(), snapo["Server"]("emulator-5554", "snapo_network_42")):
        print("ready", flush=True)
        signal.pause()
except KeyboardInterrupt:
    pass
'''
        process = subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), "ready")
            process.send_signal(signal.SIGINT)
            self.assertEqual(process.stdout.readline().strip(), "removing")
            process.send_signal(signal.SIGTERM)
            output, _ = process.communicate(timeout=5)
            self.assertIn("removed", output)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

    def test_parser_leaves_default_adb_endpoint_to_configured_adb(self):
        options = snapo.parser().parse_args(["network", "list"])
        self.assertIsNone(options.adb_host)
        self.assertIsNone(options.adb_port)

    def test_parser_requires_both_explicit_adb_endpoint_options(self):
        commands = (
            ["network", "list"],
            ["network", "requests"],
            ["network", "show", "--request-id", "request-1"],
        )
        incomplete_options = (
            ["--adb-host", "adb.example.test"],
            ["--adb-port", "15037"],
        )
        for command in commands:
            for endpoint in incomplete_options:
                with self.subTest(command=command[1], endpoint=endpoint[0]):
                    errors = io.StringIO()
                    with contextlib.redirect_stderr(errors):
                        with self.assertRaises(SystemExit) as error:
                            snapo.parser().parse_args(command + endpoint)
                    self.assertEqual(error.exception.code, 2)
                    self.assertIn("--adb-host and --adb-port must be used together", errors.getvalue())

    def test_parser_accepts_complete_explicit_adb_endpoint(self):
        options = snapo.parser().parse_args(
            ["network", "list", "--adb-host", "adb.example.test", "--adb-port", "15037"]
        )
        self.assertEqual(options.adb_host, "adb.example.test")
        self.assertEqual(options.adb_port, 15037)

    def test_parser_accepts_exclusion_first_filters(self):
        for value in ("-private", "-private other", '-"private path"'):
            with self.subTest(value=value):
                options = snapo.parser().parse_args(
                    ["network", "requests", "--filter", value, "--json"]
                )
                self.assertEqual(options.filter, value)
                self.assertTrue(options.json)

    def test_parser_preserves_missing_filter_value_errors(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                snapo.parser().parse_args(["network", "requests", "--filter", "--json"])

    def test_default_endpoint_does_not_override_configured_adb_wrapper(self):
        recorded = []

        def run(command, **kwargs):
            recorded.append(command)
            return type("Result", (), {"returncode": 0, "stdout": "", "stderr": ""})()

        adb = snapo.ADB("/configured/adb-wrapper", run=run)
        self.assertFalse(adb.has_explicit_endpoint)
        self.assertEqual(adb.endpoint, ("127.0.0.1", 5037))
        adb.command("devices", "-l", serial="emulator-5554")
        self.assertEqual(
            recorded,
            [["/configured/adb-wrapper", "-s", "emulator-5554", "devices", "-l"]],
        )

    def test_resolves_sdk_adb_when_path_is_empty(self):
        with tempfile.TemporaryDirectory() as root:
            platform_tools = pathlib.Path(root) / "platform-tools"
            platform_tools.mkdir()
            executable = platform_tools / "adb"
            executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            executable.chmod(0o755)
            self.assertEqual(
                snapo.resolve_adb(
                    environ={"ANDROID_SDK_ROOT": root},
                    which=lambda name: None,
                ),
                str(executable),
            )

    def test_passes_explicit_adb_server_and_serial(self):
        recorded = []

        def run(command, **kwargs):
            recorded.append(command)
            return type("Result", (), {"returncode": 0, "stdout": "", "stderr": ""})()

        adb = snapo.ADB("/configured/adb", host="adb.example.test", port=15037, run=run)
        self.assertTrue(adb.has_explicit_endpoint)
        adb.command("devices", "-l", serial="emulator-5554")
        self.assertEqual(
            recorded,
            [["/configured/adb", "-H", "adb.example.test", "-P", "15037", "-s", "emulator-5554", "devices", "-l"]],
        )

    def test_adb_subprocess_timeout_is_reported(self):
        def run(command, **kwargs):
            raise snapo.subprocess.TimeoutExpired(command, kwargs["timeout"])

        adb = snapo.ADB("/configured/adb", run=run, timeout=0.01)
        with self.assertRaisesRegex(snapo.SnapOError, "timed out"):
            adb.devices()

    def test_forward_uses_adb_allocated_port_and_removes_only_its_forward(self):
        adb = FakeADB(forward_port=27186)
        server = snapo.Server("emulator-5554", "snapo_network_42")
        with snapo.Forward(adb, server) as forward:
            self.assertEqual(forward.port, 27186)
        self.assertEqual(
            adb.calls,
            [
                ("emulator-5554", ("forward", "tcp:0", "localabstract:snapo_network_42")),
                ("emulator-5554", ("forward", "--remove", "tcp:27186")),
            ],
        )

    def test_forward_is_removed_when_session_work_fails(self):
        adb = FakeADB()
        server = snapo.Server("emulator-5554", "snapo_network_42")
        with self.assertRaisesRegex(RuntimeError, "expected"):
            with snapo.Forward(adb, server):
                raise RuntimeError("expected")
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", "tcp:27185")))

    def test_forward_rejects_an_invalid_allocated_port(self):
        adb = FakeADB(forward_port="invalid")
        server = snapo.Server("emulator-5554", "snapo_network_42")
        with self.assertRaisesRegex(snapo.SnapOError, "allocated forwarding port"):
            with snapo.Forward(adb, server):
                self.fail("forward unexpectedly opened")

    def test_network_forward_is_removed_when_session_close_fails(self):
        adb = FakeADB()
        server = snapo.Server("emulator-5554", "snapo_network_42")
        transport = mock.Mock(socket=mock.Mock())
        with mock.patch.object(snapo.ServerConnection, "open_socket", return_value=transport):
            session = mock.Mock()
            session.close.side_effect = RuntimeError("close failed")
            with mock.patch.object(snapo, "Session", return_value=session):
                with self.assertRaisesRegex(RuntimeError, "close failed"):
                    with snapo.ConnectedSession(adb, server):
                        pass

        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", "tcp:27185")))

    def test_tweak_forward_is_removed_when_connection_close_fails(self):
        adb = FakeADB()
        server = snapo.Server("emulator-5554", "snapo_tweaks_42")
        connection = snapo.TweakConnection(adb, server)
        with mock.patch.object(connection, "close", side_effect=RuntimeError("close failed")):
            with self.assertRaisesRegex(RuntimeError, "close failed"):
                with connection:
                    pass

        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", "tcp:27185")))


class ProtocolTests(unittest.TestCase):
    def test_manifest_reader_uses_adb_shell_without_forwarding_or_http(self):
        completed = subprocess.CompletedProcess([], 0, json.dumps(process_manifest()), "")
        with mock.patch.object(snapo.subprocess, "run", return_value=completed) as run:
            adb = snapo.ADB("/configured/adb", run=run)
            info = snapo.read_tool_metadata(adb, snapo.Server("phone", "snapo_network_42"))
        self.assertEqual(info["processIdentity"], "boot:42:1")
        command = run.call_args.args[0]
        self.assertEqual(command[:4], ["/configured/adb", "-s", "phone", "shell"])
        self.assertIn("app_process / com.openai.snapo.discovery.Main snapo_network_42", command[4])
        self.assertEqual(run.call_count, 1)

    def test_manifest_reads_batch_by_device_and_limit(self):
        servers = [snapo.Server("phone", f"snapo_network_{pid}") for pid in range(1, 66)]
        servers.append(snapo.Server("tablet", "snapo_tweaks_42"))
        adb = FakeADB()
        records = snapo.read_manifests(adb, servers)
        self.assertEqual([len(names) for _, names in adb.metadata_calls], [64, 1, 1])
        self.assertEqual([device for device, _ in adb.metadata_calls], ["phone", "phone", "tablet"])
        self.assertEqual(len(records), 66)
        self.assertEqual(adb.calls, [])

    def test_manifest_requires_process_identity_only_for_successful_records(self):
        for identity in (None, "", " ", 42):
            record = process_manifest()
            record["processIdentity"] = identity
            with self.subTest(identity=identity), self.assertRaisesRegex(snapo.SnapOError, "process identity"):
                snapo.decode_manifests(json.dumps(record))
        error = {"version": 1, "pid": 42, "error": "process exited"}
        self.assertEqual(snapo.decode_manifests(json.dumps(error)), [error])
        self.assertEqual(snapo.decode_manifests(json.dumps(process_manifest())), [process_manifest()])

    def test_manifest_reader_rejects_invalid_input(self):
        for output in ("not json", "[]", '{"version":2,"pid":42}', '{"version":1,"pid":0}'):
            with self.subTest(output=output), self.assertRaises(snapo.SnapOError):
                snapo.decode_manifests(output)
        for names in ([], ["snapo_network_42;exit"], ["snapo_network_42"] * 65):
            with self.subTest(names=names), self.assertRaises(snapo.SnapOError):
                snapo.manifest_command(b"reader", names)

    def test_manifest_reader_cleans_up_after_success_and_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            command = snapo.manifest_command(b"reader", ["snapo_network_42"]).replace("/data/local/tmp", directory)
            for status in (0, 7):
                script = f'app_process() {{ cat "$CLASSPATH"; return {status}; }};\n' + command
                result = subprocess.run(["/bin/sh", "-c", script], capture_output=True, timeout=5)
                self.assertEqual(result.returncode, status)
                self.assertEqual(result.stdout, b"reader")
                self.assertEqual(list(pathlib.Path(directory).iterdir()), [])

    def test_concurrent_manifest_readers_keep_their_own_helper_until_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            readers = []
            try:
                for helper in (b"first reader", b"second reader"):
                    command = snapo.manifest_command(helper, ["snapo_network_42"]).replace("/data/local/tmp", directory)
                    # Pause both runtimes after upload, before either opens its helper.
                    script = 'app_process() { printf "ready\\n"; read -r proceed; cat "$CLASSPATH"; };\n' + command
                    process = subprocess.Popen(
                        ["/bin/sh", "-c", script], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    )
                    readers.append((process, helper))
                    self.assertTrue(select.select([process.stdout], [], [], 5)[0], "Reader did not start")
                    self.assertEqual(process.stdout.readline(), b"ready\n")
                for process, helper in reversed(readers):
                    output, error = process.communicate(b"continue\n", timeout=5)
                    self.assertEqual(process.returncode, 0, error)
                    self.assertEqual(output, helper)
                self.assertEqual(list(pathlib.Path(directory).iterdir()), [])
            finally:
                for process, _ in readers:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=5)

    def test_manifest_reader_locations_and_missing_installation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            script = root / "MacOS/snapo"
            script.parent.mkdir()
            resources = root / "Resources"
            resources.mkdir()
            with mock.patch.object(snapo, "__file__", str(script)):
                with self.assertRaisesRegex(snapo.SnapOError, "reinstall"):
                    snapo.discovery_helper()
                bundled = resources / "snapo-discovery.jar"
                bundled.write_bytes(b"reader")
                self.assertEqual(snapo.discovery_helper(), bundled.resolve())
                standalone = script.with_name("snapo-discovery.jar")
                standalone.write_bytes(b"reader")
                self.assertEqual(snapo.discovery_helper(), standalone.resolve())

    def test_commands_reject_old_future_and_missing_versions_before_http(self):
        for kind, index, supported, connection_type in (
            ("network", 0, 3, snapo.ConnectedSession),
            ("tweaks", 1, 7, snapo.TweakConnection),
        ):
            for version in (None, True, "3", 0, 1, supported - 1, supported + 1):
                adb = FakeADB()
                adb.manifest["app"]["inspectors"][index]["protocolVersion"] = version
                with self.subTest(kind=kind, version=version):
                    with mock.patch.object(snapo.ServerConnection, "open_socket") as open_socket:
                        with self.assertRaisesRegex(snapo.SnapOError, "Unsupported .* Tool protocol"):
                            with connection_type(adb, snapo.Server("phone", f"snapo_{kind}_42")):
                                self.fail("unsupported connection opened")
                        open_socket.assert_not_called()
            adb.manifest["app"]["inspectors"] = []
            with self.assertRaisesRegex(snapo.SnapOError, "no valid manifest descriptor"):
                snapo.read_tool_metadata(adb, snapo.Server("phone", f"snapo_{kind}_42"))

    def test_shared_history_fixture_contains_only_sequenced_network_events(self):
        root = REPOSITORY / "contracts" / "network" / "v2"
        app = json.loads((root / "app.json").read_text())
        records = [json.loads(line) for line in (root / "history.jsonl").read_text().splitlines()]
        self.assertEqual(app["protocolVersion"], 2)
        with WireServer(lambda *_: self.fail("No stream expected"), history=records, watermark=3) as wire:
            history = snapo.NetworkHistory(lambda timeout: snapo.LocalAbstractSocket(port=wire.port, timeout=timeout))
            try:
                self.assertEqual([history.read() for _ in records], records)
                self.assertIsNone(history.read())
            finally:
                history.close()

    def test_incomplete_http_history_cannot_be_mistaken_for_completion(self):
        event = {**request_event(), "snapoSequence": 1}
        with WireServer(lambda *_: None, history=[event], watermark=1, complete_history=False) as wire:
            history = snapo.NetworkHistory(lambda timeout: snapo.LocalAbstractSocket(port=wire.port, timeout=timeout))
            try:
                self.assertEqual(history.read(), event)
                with self.assertRaisesRegex(snapo.SnapOError, "Unable to read network history"):
                    history.read()
            finally:
                history.close()

    def test_history_rejects_an_invalid_snapshot_cursor(self):
        with WireServer(lambda *_: None, watermark="invalid") as wire:
            with self.assertRaisesRegex(snapo.SnapOError, "Invalid history snapshot headers"):
                snapo.NetworkHistory(lambda timeout: snapo.LocalAbstractSocket(port=wire.port, timeout=timeout))

    def test_metadata_does_not_open_an_event_stream(self):
        with WireServer(lambda *_: self.fail("Metadata must not use HTTP")) as wire:
            adb = FakeADB(forward_port=str(wire.port))
            info = snapo.read_tool_metadata(adb, snapo.Server("emulator-5554", "snapo_network_42"))
        self.assertEqual(info["packageName"], "com.example")
        self.assertEqual(wire.http_requests, [])
        self.assertEqual(wire.received, [])

    def test_http_history_joins_live_events_without_duplicates(self):
        history = {**request_event(), "snapoSequence": 1}
        live = {**response_event(), "snapoSequence": 2}
        def handler(stream, received):
            write_message(stream, history)
            write_message(stream, live)
        with WireServer(handler, history=[history], watermark=1) as wire:
            session = open_session(wire.port)
            try:
                session.start_stream()
                self.assertEqual(session.read(1), history)
                self.assertIsNone(session.read(1))
                self.assertFalse(session.replaying)
                self.assertEqual(session.read(1), live)
            finally:
                session.close()
        self.assertEqual(wire.http_requests, ["/network", "/network"])

    def test_explicit_adb_endpoint_uses_direct_smart_socket_transport(self):
        with WireServer(lambda *_: None, adb_handshake=True) as wire:
            adb = snapo.ADB("/configured/adb", host="127.0.0.1", port=wire.port)
            adb.tool_metadata = mock.Mock(return_value=[process_manifest()])
            with snapo.ConnectedSession(adb, snapo.Server("emulator-5554", "snapo_network_42")) as session:
                session.start_stream()
                self.assertIsNone(session.read(1))
        self.assertEqual(wire.received, ["host:transport:emulator-5554", "localabstract:snapo_network_42"] * 2)

    def test_invalid_live_records_fail_visibly(self):
        for message in (None, [], 42, {"method": "Network.loadingFinished", "params": []}):
            with self.subTest(message=message):
                with WireServer(lambda stream, _: write_message(stream, message)) as wire:
                    session = open_session(wire.port)
                    try:
                        session.start_stream()
                        with self.assertRaisesRegex(snapo.SnapOError, "Invalid network event"):
                            for _ in range(3):
                                session.read(1)
                    finally:
                        session.close()

    def test_body_reads_do_not_subscribe_and_encode_request_ids(self):
        with WireServer(lambda *_: self.fail("No stream expected"), bodies={"response-body": {"body": "hello", "base64Encoded": False}}) as wire:
            session = open_session(wire.port)
            try:
                self.assertEqual(session.body("a/b ?", True), {"body": "hello", "base64Encoded": False})
            finally:
                session.close()
        self.assertEqual(wire.http_requests, ["/network/requests/a%2Fb%20%3F/response-body"])

    def test_live_buffer_overflow_fails_visibly(self):
        session = snapo.Session(None)
        message = {**request_event(), "snapoSequence": 1}
        session.events = mock.Mock()
        session.events.read_event.return_value = {"data": message, "id": "1", "size": 1}
        session._read_loop()
        with self.assertRaisesRegex(snapo.SnapOError, "buffer filled"):
            session.read(1)
        session.close()

    def test_fetches_both_bodies_and_redacts_headers(self):
        history = [{**event, "snapoSequence": index} for index, event in enumerate([
            request_event(), response_event(), {"method": "Network.loadingFinished", "params": {"requestId": "request-1"}}], 1)]
        bodies = {"request-body": {"postData": '{"hello":"world"}'}, "response-body": {"body": '{"ok":true}', "base64Encoded": False}}
        with WireServer(lambda *_: None, history=history, watermark=3, bodies=bodies) as wire:
            session = open_session(wire.port)
            try:
                details = snapo.request_details(session, snapo.Server("emulator-5554", "snapo_network_42"), "request-1")
            finally:
                session.close()
        self.assertEqual(details["requestBody"], '{"hello":"world"}')
        self.assertEqual(details["responseBody"], '{"ok":true}')
        self.assertFalse(details["responseBodyBase64Encoded"])
        self.assertEqual(details["requestHeaders"]["Authorization"], snapo.REDACTED)
        self.assertEqual(details["requestHeaders"]["Cookie"], snapo.REDACTED)
        self.assertEqual(details["responseHeaders"]["Set-Cookie"], snapo.REDACTED)

    def test_empty_response_bodies_preserve_details(self):
        for length in (None, "00"):
            with self.subTest(length=length):
                request = request_event()
                request["params"]["request"]["hasPostData"] = False
                response = response_event()
                if length is not None:
                    response["params"]["response"]["headers"]["Content-Length"] = length
                history = [{**event, "snapoSequence": index} for index, event in enumerate([
                    request, response, {"method": "Network.loadingFinished", "params": {"requestId": "request-1"}}], 1)]
                with WireServer(lambda *_: None, history=history, watermark=3) as wire:
                    session = open_session(wire.port)
                    try:
                        details = snapo.request_details(session, snapo.Server("emulator-5554", "snapo_network_42"), "request-1")
                    finally:
                        session.close()
                self.assertEqual(details["responseStatus"], 200)
                self.assertEqual(details["responseBody"], "")
                self.assertEqual(any("response-body" in path for path in wire.http_requests), length is None)

    def test_request_details_keeps_waiting_while_replay_is_active(self):
        clock = {"now": 0}
        request = request_event()
        request["params"]["request"]["hasPostData"] = False

        class SlowReplaySession:
            replaying = True
            def __init__(self):
                self.messages = [
                    {"method": "Network.loadingFinished", "params": {"requestId": "other"}},
                    {"method": "Network.loadingFinished", "params": {"requestId": "other"}},
                    {"method": "Network.loadingFinished", "params": {"requestId": "other"}},
                    request,
                    response_event(),
                    {"method": "Network.loadingFinished", "params": {"requestId": "request-1"}},
                ]

            def start_stream(self):
                return None

            def read(self, timeout):
                clock["now"] += 2
                return self.messages.pop(0)

            def body(self, request_id, response=False):
                return {"body": "", "base64Encoded": False}

        with mock.patch.object(snapo.time, "monotonic", side_effect=lambda: clock["now"]):
            details = snapo.request_details(
                SlowReplaySession(),
                snapo.Server("emulator-5554", "snapo_network_42"),
                "request-1",
            )

        self.assertEqual(details["responseStatus"], 200)
        self.assertGreater(clock["now"], 5)

    def test_request_details_times_out_for_missing_request_during_live_traffic(self):
        clock = {"now": 0}

        class UnrelatedLiveTrafficSession:
            replaying = False
            def __init__(self):
                self.reads = 0

            def start_stream(self):
                return None

            def read(self, timeout):
                self.reads += 1
                if self.reads > 10:
                    raise AssertionError("request lookup kept extending its deadline after replay")
                clock["now"] += 1
                if self.reads == 1:
                    return None
                return {"method": "Network.loadingFinished", "params": {"requestId": "unrelated"}}

        session = UnrelatedLiveTrafficSession()
        with mock.patch.object(snapo.time, "monotonic", side_effect=lambda: clock["now"]):
            with self.assertRaisesRegex(snapo.SnapOError, "Timed out waiting for network lifecycle"):
                snapo.request_details(
                    session,
                    snapo.Server("emulator-5554", "snapo_network_42"),
                    "missing-request",
                )

        self.assertLessEqual(session.reads, 6)

    def test_large_zero_content_length_does_not_require_integer_conversion(self):
        state = snapo.RequestState("request-1")
        state.response_headers = {"Content-Length": "0" * 5000}
        self.assertTrue(state.has_no_response_body())

        state.response_headers = {"Content-Length": "0" * 4999 + "1"}
        self.assertFalse(state.has_no_response_body())


class TweakTransportTests(unittest.TestCase):
    def test_local_http_transport_creates_and_removes_only_its_tweak_forward(self):
        adb = FakeTweakADB()
        server = snapo.Server("emulator-5554", "snapo_tweaks_42")
        with TweakHTTPServer() as wire:
            adb.forward_port = wire.port
            with snapo.TweakConnection(adb, server) as connection:
                response = connection.request("GET", "/tweaks")

        self.assertEqual(response["tweaks"][0]["name"], "Typography/Font size")
        self.assertEqual(
            adb.calls,
            [
                ("emulator-5554", ("forward", "tcp:0", "localabstract:snapo_tweaks_42")),
                ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")),
            ],
        )

    def test_explicit_adb_endpoint_sends_http_through_direct_smart_socket(self):
        payload = {"tweaks": tweak_descriptors()}
        with TweakSmartSocketServer(payload) as wire:
            adb = snapo.ADB("/configured/adb", host="127.0.0.1", port=wire.port)
            adb.tool_metadata = mock.Mock(return_value=[process_manifest()])
            server = snapo.Server("emulator-5554", "snapo_tweaks_42")
            with snapo.TweakConnection(adb, server) as connection:
                response = connection.request("GET", "/tweaks")

        self.assertEqual(response, payload)
        self.assertEqual(
            wire.received,
            [
                "host:transport:emulator-5554",
                "localabstract:snapo_tweaks_42",
                "GET /tweaks HTTP/1.1",
            ],
        )
        self.assertNotIn("GET /network HTTP/1.1", " ".join(wire.received))

    def test_http_errors_include_status_and_server_message(self):
        adb = FakeTweakADB()
        server = snapo.Server("emulator-5554", "snapo_tweaks_42")
        for status, detail in ((404, "Unknown tweak: Missing"), (422, "Value exceeds the maximum.")):
            with self.subTest(status=status):
                with TweakHTTPServer(error=(status, detail)) as wire:
                    adb.forward_port = wire.port
                    with snapo.TweakConnection(adb, server) as connection:
                        with self.assertRaisesRegex(snapo.SnapOError, f"HTTP {status}.*{detail}"):
                            connection.request("PATCH", "/tweaks", {"values": {"Motion/Enabled": False}})

                self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_oversized_http_responses_are_rejected_and_forward_is_removed(self):
        adb = FakeTweakADB()
        server = snapo.Server("emulator-5554", "snapo_tweaks_42")
        with TweakHTTPServer() as wire:
            adb.forward_port = wire.port
            with mock.patch.object(snapo, "MAX_RECORD_BYTES", 16):
                with self.assertRaisesRegex(snapo.SnapOError, "oversized"):
                    with snapo.TweakConnection(adb, server) as connection:
                        connection.request("GET", "/tweaks")

        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))


class TweakCommandTests(unittest.TestCase):
    def run_command(self, arguments, wire, adb=None):
        adb = adb or FakeTweakADB()
        adb.forward_port = wire.port
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(snapo, "resolve_adb", return_value="/configured/adb"):
            with mock.patch.object(snapo, "ADB", return_value=adb):
                with contextlib.redirect_stdout(stdout):
                    with contextlib.redirect_stderr(stderr):
                        result = snapo.main(["tweaks", *arguments])
        return result, stdout.getvalue(), stderr.getvalue(), adb

    def test_apps_identifies_each_running_application_from_its_tweak_server(self):
        with TweakHTTPServer() as wire:
            result, output, errors, adb = self.run_command(["apps", "--json"], wire)

        self.assertEqual(result, 0, errors)
        app = json.loads(output)
        self.assertEqual(app["deviceId"], "emulator-5554")
        self.assertEqual(app["socketName"], "snapo_tweaks_42")
        self.assertEqual(app["appName"], "Snap-O Tweaks Demo")
        self.assertEqual(app["packageName"], "com.example.tweaks")
        self.assertEqual(app["protocolVersion"], 7)
        self.assertEqual(wire.requests, [])
        self.assertEqual(adb.calls, [])
        self.assertEqual(adb.metadata_calls, [("emulator-5554", ["snapo_tweaks_42"])])


    def test_apps_keeps_other_processes_visible_when_metadata_fails(self):
        adb = FakeTweakADB(sockets={"emulator-5554": ["snapo_tweaks_41", "snapo_tweaks_42"]})
        adb.tool_metadata = mock.Mock(return_value=[
            {"version": 1, "pid": 41, "error": "process exited"}, adb.manifest,
        ])
        with TweakHTTPServer() as wire:
            result, output, errors, _ = self.run_command(["apps", "--json"], wire, adb)
        self.assertEqual(result, 0)
        self.assertIn("process exited", errors)
        rows = [json.loads(line) for line in output.splitlines()]
        self.assertEqual([row["socketName"] for row in rows], ["snapo_tweaks_41", "snapo_tweaks_42"])
        self.assertEqual(rows[1]["appName"], "Snap-O Tweaks Demo")
        self.assertEqual(wire.requests, [])
        self.assertEqual(adb.calls, [])

    def test_apps_preserves_future_tweak_protocol_versions(self):
        adb = FakeTweakADB()
        adb.manifest["app"]["inspectors"][1]["protocolVersion"] = 8
        with TweakHTTPServer() as wire:
            result, output, errors, _ = self.run_command(["apps", "--json"], wire, adb)
        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output)["protocolVersion"], 8)
        self.assertEqual(wire.requests, [])


    def test_apps_preserves_existing_human_readable_output(self):
        with TweakHTTPServer() as wire:
            result, output, errors, _ = self.run_command(["apps"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(
            output,
            "emulator-5554:\n    snapo_tweaks_42  Snap-O Tweaks Demo  pkg:com.example.tweaks\n",
        )

    def test_network_discovery_does_not_include_tweak_protocol_version(self):
        options = snapo.parser().parse_args(["network", "list", "--no-app-info", "--json"])
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = snapo.run_list(FakeADB(), options)

        self.assertEqual(result, 0)
        self.assertNotIn("protocolVersion", json.loads(output.getvalue()))

    def test_list_emits_one_complete_json_snapshot(self):
        with TweakHTTPServer() as wire:
            result, output, errors, adb = self.run_command(["list", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), {"tweaks": wire.descriptors})
        self.assertEqual(wire.requests, [("GET", "/tweaks", None)])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_list_all_includes_previously_adjusted_inactive_tweaks(self):
        active = tweak_descriptors()[0]
        inactive = {**tweak_descriptors()[1], "name": "Motion/Historical duration", "value": 0.7, "modified": True}

        with TweakHTTPServer(descriptors=[active], adjusted_descriptors=[active, inactive]) as wire:
            result, output, errors, adb = self.run_command(["list", "--all", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), {"tweaks": [active, inactive]})
        self.assertEqual(wire.requests, [("GET", "/tweaks?include=adjusted", None)])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_list_all_preserves_independently_adjusted_tweaks_with_the_same_name(self):
        active = tweak_descriptors()[1]
        first = {**tweak_descriptors()[0], "value": 20, "modified": True}
        second = {**first, "default": 24, "value": 32, "max": 64}
        expanded = [active, first, second]

        with TweakHTTPServer(descriptors=[active], adjusted_descriptors=expanded) as wire:
            result, output, errors, _ = self.run_command(["list", "--all", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), {"tweaks": expanded})
        self.assertEqual(wire.requests, [("GET", "/tweaks?include=adjusted", None)])

    def test_list_renders_descriptive_human_readable_values(self):
        with TweakHTTPServer() as wire:
            result, output, errors, _ = self.run_command(["list"], wire)

        self.assertEqual(result, 0, errors)
        self.assertIn("Typography/Font size = 16 [int]", output)
        self.assertIn("Motion/Enabled = true [boolean]", output)
        self.assertIn('Preview/Text value = "true" [string]', output)
        self.assertIn('Appearance/Theme = "System" [enum]; options: ["System", "Light", "Dark"]', output)

    def test_list_renders_actions_without_fabricating_values_and_surfaces_conflicts(self):
        descriptors = [
            *tweak_descriptors(),
            {"name": "Preview/Refresh", "type": "action"},
            {"name": "Preview/Reload", "type": "action", "conflicted": True},
        ]
        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(["list"], wire)

        self.assertEqual(result, 0, errors)
        self.assertIn("Preview/Refresh [action]", output)
        self.assertIn("Preview/Reload [action, conflicted]", output)
        self.assertNotIn("Preview/Refresh =", output)
        self.assertNotIn("Preview/Reload =", output)

    def test_list_preserves_complete_action_descriptors_in_json_snapshots(self):
        descriptors = [
            *tweak_descriptors(),
            {"name": "Preview/Refresh", "type": "action"},
            {"name": "Preview/Reload", "type": "action", "conflicted": True},
        ]
        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(["list", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), {"tweaks": descriptors})

    def test_list_does_not_infer_missing_modified_state_from_value(self):
        descriptors = tweak_descriptors()
        descriptors[0]["value"] = 20

        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(["list", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), {"tweaks": descriptors})
        self.assertNotIn("modified", json.loads(output)["tweaks"][0])

    def test_list_preserves_modified_state_when_value_matches_default(self):
        descriptors = tweak_descriptors()
        descriptors[0]["modified"] = True

        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(["list", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), {"tweaks": descriptors})
        self.assertTrue(json.loads(output)["tweaks"][0]["modified"])

    def test_get_accepts_tweak_names_with_slashes_and_spaces(self):
        with TweakHTTPServer() as wire:
            result, output, errors, _ = self.run_command(["get", "Typography/Font size", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), wire.descriptors[0])
        self.assertEqual(wire.requests, [("GET", "/tweaks", None)])

    def test_get_displays_an_action_descriptor_without_a_value(self):
        action = {"name": "Preview/Refresh", "type": "action"}
        with TweakHTTPServer(descriptors=[action]) as wire:
            result, output, errors, _ = self.run_command(["get", action["name"]], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(output, "Preview/Refresh [action]\n")
        self.assertEqual(wire.requests, [("GET", "/tweaks", None)])

    def test_get_all_finds_a_previously_adjusted_inactive_tweak(self):
        active = tweak_descriptors()[0]
        inactive = {**tweak_descriptors()[1], "name": "Motion/Historical duration", "value": 0.7, "modified": True}

        with TweakHTTPServer(descriptors=[active], adjusted_descriptors=[active, inactive]) as wire:
            result, output, errors, adb = self.run_command(
                ["get", inactive["name"], "--all", "--json"],
                wire,
            )

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), inactive)
        self.assertEqual(wire.requests, [("GET", "/tweaks?include=adjusted", None)])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_get_all_rejects_independently_adjusted_tweaks_with_the_same_name(self):
        active = tweak_descriptors()[1]
        first = {**tweak_descriptors()[0], "value": 20, "modified": True}
        second = {**first, "default": 24, "value": 32, "max": 64}

        with TweakHTTPServer(descriptors=[active], adjusted_descriptors=[active, first, second]) as wire:
            result, output, errors, adb = self.run_command(["get", first["name"], "--all", "--json"], wire)

        self.assertEqual(result, 1)
        self.assertEqual(output, "")
        self.assertIn(f"Multiple tweaks named '{first['name']}'", errors)
        self.assertIn("snapo tweaks list --all --json", errors)
        self.assertEqual(wire.requests, [("GET", "/tweaks?include=adjusted", None)])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_get_reports_unknown_tweaks_without_mutating_the_application(self):
        with TweakHTTPServer() as wire:
            result, output, errors, adb = self.run_command(["get", "Motion/Missing", "--json"], wire)

        self.assertEqual(result, 1)
        self.assertEqual(output, "")
        self.assertIn("Unknown tweak: Motion/Missing", errors)
        self.assertEqual([request[0] for request in wire.requests], ["GET"])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_set_parses_values_using_each_descriptor_type(self):
        cases = (
            ("Typography/Font size", "-2", -2),
            ("Motion/Damping ratio", "-0.5", -0.5),
            ("Motion/Enabled", "false", False),
            ("Palette/Accent color", "#3b82f6", "#3B82F6"),
            ("Preview/Text value", "true", "true"),
            ("Appearance/Theme", "Dark", "Dark"),
            ("Preview/Text value", "-hello", "-hello"),
            ("Preview/Text value", "-foo", "-foo"),
            ("Preview/Text value", "--literal", "--literal"),
            ("Preview/Text value", "-h", "-h"),
            ("Preview/Text value", "--help", "--help"),
        )
        for name, raw, expected in cases:
            with self.subTest(name=name, value=raw):
                with TweakHTTPServer() as wire:
                    result, output, errors, adb = self.run_command(["set", name, raw], wire)

                self.assertEqual(result, 0, errors)
                self.assertEqual(output, "")
                self.assertEqual(wire.requests[0], ("GET", "/tweaks", None))
                self.assertEqual(len(wire.requests), 2)
                self.assertEqual(wire.requests[1][0:2], ("PATCH", "/tweaks"))
                sent = wire.requests[1][2]["values"][name]
                if isinstance(expected, str) and name == "Palette/Accent color":
                    self.assertEqual(sent.upper(), expected)
                else:
                    self.assertEqual(sent, expected)
                self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_set_rejects_invalid_values_without_sending_a_patch(self):
        cases = (
            ("Typography/Font size", "3.5"),
            ("Motion/Damping ratio", "NaN"),
            ("Motion/Damping ratio", "inf"),
            ("Motion/Enabled", "probably"),
            ("Palette/Accent color", "#nothex"),
            ("Appearance/Theme", "dark"),
            ("Appearance/Theme", "DARK"),
            ("Appearance/Theme", "Dark mode"),
        )
        for name, raw in cases:
            with self.subTest(name=name, value=raw):
                with TweakHTTPServer() as wire:
                    result, output, errors, adb = self.run_command(["set", name, raw], wire)

                self.assertEqual(result, 1)
                self.assertEqual(output, "")
                self.assertTrue(errors.startswith("snapo:"), errors)
                self.assertEqual(wire.requests, [("GET", "/tweaks", None)])
                self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_set_rejects_actions_without_sending_a_patch(self):
        action = {"name": "Preview/Refresh", "type": "action"}
        with TweakHTTPServer(descriptors=[action]) as wire:
            result, output, errors, adb = self.run_command(["set", action["name"], "true"], wire)

        self.assertEqual(result, 1)
        self.assertEqual(output, "")
        self.assertIn(f"Action '{action['name']}' cannot be set", errors)
        self.assertIn("snapo tweaks action NAME", errors)
        self.assertEqual(wire.requests, [("GET", "/tweaks", None)])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_action_invokes_the_exact_app_owned_name_without_fetching_a_snapshot(self):
        action = {"name": "Preview/Refresh visible content", "type": "action"}
        with TweakHTTPServer(descriptors=[action]) as wire:
            result, output, errors, adb = self.run_command(["action", action["name"]], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(output, "")
        self.assertEqual(wire.requests, [("POST", "/tweaks/action", {"name": action["name"]})])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_action_surfaces_unknown_non_action_and_conflicting_registrations(self):
        conflicted = {"name": "Preview/Reload", "type": "action", "conflicted": True}
        value = tweak_descriptors()[0]
        cases = (
            ("Preview/Missing", 404, "Unknown action: Preview/Missing"),
            (value["name"], 404, f"Unknown action: {value['name']}"),
            (conflicted["name"], 409, f"Conflicting action registrations: {conflicted['name']}"),
        )
        for name, status, detail in cases:
            with self.subTest(name=name):
                with TweakHTTPServer(descriptors=[value, conflicted]) as wire:
                    result, output, errors, adb = self.run_command(["action", name], wire)

                self.assertEqual(result, 1)
                self.assertEqual(output, "")
                self.assertIn(f"HTTP {status}", errors)
                self.assertIn(detail, errors)
                self.assertEqual(wire.requests, [("POST", "/tweaks/action", {"name": name})])
                self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_set_updates_the_modified_state(self):
        with TweakHTTPServer() as wire:
            result, output, errors, _ = self.run_command(["set", "Typography/Font size", "24"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(output, "")
        self.assertEqual(wire.descriptors[0]["value"], 24)
        self.assertTrue(wire.descriptors[0]["modified"])

    def test_set_reports_a_named_batch_error(self):
        name = "Motion/Enabled"
        with TweakHTTPServer(
            update_errors={name: "The value could not be changed."},
        ) as wire:
            result, output, errors, _ = self.run_command(["set", name, "false"], wire)

        self.assertEqual(result, 1)
        self.assertEqual(output, "")
        self.assertIn(name, errors)
        self.assertIn("The value could not be changed.", errors)
        self.assertTrue(next(item for item in wire.descriptors if item["name"] == name)["value"])

    def test_reset_one_tweak_sends_a_null_value(self):
        descriptors = tweak_descriptors()
        descriptors[0]["value"] = 24
        descriptors[0]["modified"] = True
        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(
                ["reset", "Typography/Font size"],
                wire,
            )

        self.assertEqual(result, 0, errors)
        self.assertEqual(wire.requests[1], ("PATCH", "/tweaks", {"values": {"Typography/Font size": None}}))
        self.assertEqual(wire.descriptors[0]["value"], 16)
        self.assertNotIn("modified", wire.descriptors[0])
        self.assertEqual(output, "")

    def test_reset_enum_sends_a_null_value(self):
        descriptors = tweak_descriptors()
        descriptor = next(item for item in descriptors if item["name"] == "Appearance/Theme")
        descriptor["value"] = "Dark"

        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(["reset", "Appearance/Theme"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(wire.requests[1], ("PATCH", "/tweaks", {"values": {"Appearance/Theme": None}}))
        self.assertEqual(
            next(item for item in wire.descriptors if item["name"] == "Appearance/Theme")["value"],
            "System",
        )
        self.assertEqual(output, "")



    def test_reset_all_keeps_successful_changes_and_reports_named_batch_errors(self):
        descriptors = tweak_descriptors()
        descriptors[0]["value"] = 24
        descriptors[2]["value"] = False
        descriptors[0]["modified"] = True
        descriptors[2]["modified"] = True
        failed_name = descriptors[2]["name"]

        with TweakHTTPServer(
            descriptors=descriptors,
            update_errors={failed_name: "The owner rejected this value."},
        ) as wire:
            result, output, errors, _ = self.run_command(["reset", "--all"], wire)

        self.assertEqual(result, 1)
        self.assertEqual(output, "")
        self.assertIn(failed_name, errors)
        self.assertIn("The owner rejected this value.", errors)
        self.assertEqual(wire.descriptors[0]["value"], 16)
        self.assertFalse(wire.descriptors[2]["value"])
        self.assertEqual(
            wire.requests[-1],
            (
                "PATCH",
                "/tweaks",
                {
                    "values": {
                        "Typography/Font size": None,
                        failed_name: None,
                    },
                },
            ),
        )

    def test_reset_all_sends_only_modified_names_with_null_values(self):
        descriptors = tweak_descriptors()
        descriptors[0]["value"] = 24
        descriptors[0]["modified"] = True
        descriptors[1]["value"] = 0.7
        descriptors[2]["value"] = False
        descriptors[2]["modified"] = True
        values = {
            descriptor["name"]: None
            for descriptor in descriptors
            if descriptor.get("modified") is True
        }
        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(["reset", "--all"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(
            wire.requests,
            [("GET", "/tweaks", None), ("PATCH", "/tweaks", {"values": values})],
        )
        self.assertEqual(wire.descriptors[1]["value"], 0.7)
        self.assertTrue(all("modified" not in descriptor for descriptor in wire.descriptors))
        self.assertEqual(output, "")

    def test_reset_all_ignores_actions_without_defaults(self):
        descriptors = [
            *tweak_descriptors(),
            {"name": "Preview/Refresh", "type": "action"},
            {"name": "Preview/Reload", "type": "action", "conflicted": True},
        ]
        descriptors[0]["value"] = 24
        descriptors[0]["modified"] = True
        values = {
            descriptor["name"]: None
            for descriptor in descriptors
            if descriptor["type"] != "action" and descriptor.get("modified") is True
        }
        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(["reset", "--all"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(
            wire.requests,
            [("GET", "/tweaks", None), ("PATCH", "/tweaks", {"values": values})],
        )
        self.assertEqual(output, "")

    def test_reset_all_with_no_modified_tweaks_sends_no_patch(self):
        descriptors = tweak_descriptors()
        descriptors[0]["value"] = 24
        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(["reset", "--all"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(wire.requests, [("GET", "/tweaks", None)])
        self.assertEqual(wire.descriptors[0]["value"], 24)
        self.assertEqual(output, "")

    def test_reset_one_unmodified_tweak_still_sends_a_null_value(self):
        descriptors = tweak_descriptors()
        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(["reset", "Typography/Font size"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(
            wire.requests,
            [
                ("GET", "/tweaks", None),
                ("PATCH", "/tweaks", {"values": {"Typography/Font size": None}}),
            ],
        )
        self.assertEqual(output, "")

    def test_reset_all_with_only_actions_sends_no_patch(self):
        action = {"name": "Preview/Refresh", "type": "action"}
        with TweakHTTPServer(descriptors=[action]) as wire:
            result, output, errors, _ = self.run_command(["reset", "--all"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(wire.requests, [("GET", "/tweaks", None)])
        self.assertEqual(output, "")

    def test_reset_rejects_an_action_without_sending_a_patch(self):
        action = {"name": "Preview/Refresh", "type": "action"}
        with TweakHTTPServer(descriptors=[action]) as wire:
            result, output, errors, _ = self.run_command(["reset", action["name"]], wire)

        self.assertEqual(result, 1)
        self.assertEqual(output, "")
        self.assertIn(f"Action '{action['name']}' cannot be reset", errors)
        self.assertIn("snapo tweaks action NAME", errors)
        self.assertEqual(wire.requests, [("GET", "/tweaks", None)])

    def test_reset_requires_exactly_one_target(self):
        for arguments in (["reset"], ["reset", "Motion/Enabled", "--all"]):
            with self.subTest(arguments=arguments):
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    with self.assertRaises(SystemExit) as error:
                        snapo.parser().parse_args(["tweaks", *arguments])
                self.assertEqual(error.exception.code, 2)
                self.assertIn("reset requires either NAME or --all", errors.getvalue())

    def test_set_requires_a_name_and_value(self):
        invalid = (
            ["set"],
            ["set", "Motion/Enabled"],
        )
        for arguments in invalid:
            with self.subTest(arguments=arguments):
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    with self.assertRaises(SystemExit) as error:
                        snapo.parser().parse_args(["tweaks", *arguments])
                self.assertEqual(error.exception.code, 2)
                self.assertIn("set", errors.getvalue())

    def test_action_requires_exactly_one_name(self):
        for arguments in (["action"], ["action", "Preview/Refresh", "unexpected"]):
            with self.subTest(arguments=arguments):
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    with self.assertRaises(SystemExit) as error:
                        snapo.parser().parse_args(["tweaks", *arguments])
                self.assertEqual(error.exception.code, 2)
                self.assertTrue(
                    "required" in errors.getvalue() or "unrecognized arguments" in errors.getvalue(),
                    errors.getvalue(),
                )

    def test_mutations_do_not_accept_json_output(self):
        for command in (
            ["set", "Motion/Enabled", "false", "--json"],
            ["action", "Preview/Refresh", "--json"],
            ["reset", "Motion/Enabled", "--json"],
        ):
            with self.subTest(command=command):
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    with self.assertRaises(SystemExit) as error:
                        snapo.parser().parse_args(["tweaks", *command])

                self.assertEqual(error.exception.code, 2)
                self.assertIn("unrecognized arguments: --json", errors.getvalue())

    def test_server_validation_errors_reach_stderr_and_remove_the_forward(self):
        for status, detail in ((404, "Unknown tweak: Motion/Enabled"), (422, "Value exceeds the maximum.")):
            with self.subTest(status=status):
                with TweakHTTPServer(error=(status, detail)) as wire:
                    result, output, errors, adb = self.run_command(
                        ["set", "Motion/Enabled", "false"],
                        wire,
                    )

                self.assertEqual(result, 1)
                self.assertEqual(output, "")
                self.assertIn(f"HTTP {status}", errors)
                self.assertIn(detail, errors)
                self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_watch_ignores_keepalives_and_other_events_then_emits_a_complete_snapshot(self):
        with TweakHTTPServer() as wire:
            result, output, errors, adb = self.run_command(["watch", "--once", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), {"tweaks": wire.descriptors})
        self.assertEqual(len(output.splitlines()), 1)
        self.assertEqual(wire.requests, [("GET", "/tweaks/events", None)])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_watch_displays_action_descriptors_without_values(self):
        action = {"name": "Preview/Refresh", "type": "action", "conflicted": True}
        with TweakHTTPServer(descriptors=[action]) as wire:
            result, output, errors, _ = self.run_command(["watch", "--once"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(output, "Preview/Refresh [action, conflicted]\n")
        self.assertEqual(wire.requests, [("GET", "/tweaks/events", None)])

    def test_watch_rejects_malformed_snapshots_and_still_removes_its_forward(self):
        events = ["event: tweaks\ndata: {\"tweaks\":\"not-a-list\"}\n\n"]
        with TweakHTTPServer(stream_events=events) as wire:
            result, output, errors, adb = self.run_command(["watch", "--once", "--json"], wire)

        self.assertEqual(result, 1)
        self.assertEqual(output, "")
        self.assertIn("invalid tweak list", errors)
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))


class OutputTests(unittest.TestCase):
    def test_sanitizes_all_sensitive_event_headers(self):
        request = snapo.sanitize_event(request_event())
        response = snapo.sanitize_event(response_event())
        self.assertEqual(request["params"]["request"]["headers"]["Authorization"], snapo.REDACTED)
        self.assertEqual(request["params"]["request"]["headers"]["Cookie"], snapo.REDACTED)
        self.assertEqual(response["params"]["response"]["headers"]["Set-Cookie"], snapo.REDACTED)

    def test_history_only_request_keeps_reading_until_http_completion(self):
        clock = {"now": 0}
        history = mock.Mock()
        messages = iter([request_event(), response_event(), {"method": "Network.loadingFinished", "params": {"requestId": "request-1"}}, None])
        def read():
            clock["now"] += 2
            return next(messages)
        history.read.side_effect = read
        server = snapo.Server("emulator-5554", "snapo_network_42")
        options = snapo.parser().parse_args(["network", "requests", "--no-stream", "--json"])
        with mock.patch.object(snapo.time, "monotonic", side_effect=lambda: clock["now"]):
            with mock.patch.object(snapo, "discover", return_value=[server]):
                with mock.patch.object(snapo, "NetworkHistory", return_value=history):
                    with contextlib.redirect_stdout(io.StringIO()):
                        result = snapo.run_requests(FakeADB(), options)
        self.assertEqual(result, 0)
        self.assertGreater(clock["now"], 5)
        history.close.assert_called_once()

    def test_filter_tracks_matching_request_lifecycle(self):
        event_filter = snapo.EventFilter('example.test -"/private api"')
        self.assertTrue(event_filter.matches(request_event()))
        self.assertTrue(
            event_filter.matches(
                {"method": "Network.loadingFinished", "params": {"requestId": "request-1"}}
            )
        )
        excluded = request_event()
        excluded["params"]["requestId"] = "excluded"
        excluded["params"]["request"]["url"] = "https://example.test/private api"
        self.assertFalse(event_filter.matches(excluded))

    def test_filter_uses_network_tool_search_grammar(self):
        cases = [
            ("don't", ["don't"], []),
            ('"unfinished phrase', ["unfinished phrase"], []),
            (r"path\segment", [r"path\segment"], []),
            (r"escaped\ space", ["escaped space"], []),
            (r'quoted\"value', ['quoted"value'], []),
            (r"path\\segment", [r"path\segment"], []),
            ('-"private path" keep', ["keep"], ["private path"]),
            ("'single quoted'", ["'single", "quoted'"], []),
        ]
        for text, includes, excludes in cases:
            with self.subTest(text=text):
                event_filter = snapo.EventFilter(text)
                self.assertEqual(event_filter.includes, includes)
                self.assertEqual(event_filter.excludes, excludes)

    def test_streamed_events_are_flushed_to_pipes_immediately(self):
        for as_json in (True, False):
            with self.subTest(as_json=as_json):
                reader, writer = os.pipe()
                try:
                    with open(writer, "w", buffering=8192) as output:
                        with contextlib.redirect_stdout(output):
                            snapo.emit_event(request_event(), as_json=as_json)
                        readable, _, _ = select.select([reader], [], [], 0)
                        self.assertEqual(readable, [reader])
                        record = os.read(reader, 65536).decode("utf-8")
                        self.assertTrue(record.endswith("\n"))
                        self.assertNotIn(REQUEST_SECRET, record)
                finally:
                    os.close(reader)

    def test_decodes_gzip_body_with_standard_library(self):
        encoded = snapo.base64.b64encode(gzip.compress(b'{"ok":true}')).decode("ascii")
        self.assertEqual(snapo.decoded_body(encoded, "base64", "gzip"), '{"ok":true}')

    def test_decodes_gzip_body_with_repeated_content_encodings(self):
        encoded = snapo.base64.b64encode(gzip.compress(b'{"ok":true}')).decode("ascii")
        for content_encoding in ("gzip\ngzip", "identity,\nx-gzip", "gzip; level=9\r\nidentity"):
            with self.subTest(content_encoding=content_encoding):
                self.assertEqual(snapo.decoded_body(encoded, "base64", content_encoding), '{"ok":true}')

    def test_truncated_gzip_body_falls_back_to_original_capture(self):
        truncated = gzip.compress(b'{"ok":true}')[:-1]
        encoded = snapo.base64.b64encode(truncated).decode("ascii")
        self.assertEqual(snapo.decoded_body(encoded, "base64", "gzip"), encoded)

    def test_requests_json_never_prints_raw_sensitive_headers_and_cleans_up(self):
        history = [{**request_event(), "snapoSequence": 1}, {**response_event(), "snapoSequence": 2}]
        def handler(*_):
            self.fail("A history-only request must not open an event stream")

        adb = FakeADB()
        stdout = io.StringIO()
        with WireServer(handler, history=history, watermark=2) as wire:
            adb.forward_port = wire.port
            with mock.patch.object(snapo, "resolve_adb", return_value="/configured/adb"):
                with mock.patch.object(snapo, "ADB", return_value=adb):
                    with contextlib.redirect_stdout(stdout):
                        code = snapo.main(
                            [
                                "network",
                                "requests",
                                "-s",
                                "emulator-5554",
                                "-n",
                                "snapo_network_42",
                                "--no-stream",
                                "--json",
                            ]
                        )
        self.assertEqual(wire.http_requests, ["/network"])
        output = stdout.getvalue()
        self.assertEqual(code, 0)
        self.assertNotIn(REQUEST_SECRET, output)
        self.assertNotIn(COOKIE_SECRET, output)
        self.assertNotIn(RESPONSE_SECRET, output)
        records = [json.loads(line) for line in output.splitlines()]
        self.assertEqual([record["method"] for record in records], ["Network.requestWillBeSent", "Network.responseReceived"])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_closed_output_pipe_exits_cleanly_and_removes_forward(self):
        class ClosedPipe:
            closed = False

            def write(self, value):
                raise BrokenPipeError

            def flush(self):
                return None

            def close(self):
                self.closed = True

        def handler(stream, received):
            write_message(stream, request_event())

        adb = FakeADB()
        output = ClosedPipe()
        with WireServer(handler) as wire:
            adb.forward_port = wire.port
            with mock.patch.object(snapo, "resolve_adb", return_value="/configured/adb"):
                with mock.patch.object(snapo, "ADB", return_value=adb):
                    with contextlib.redirect_stdout(output):
                        code = snapo.main(
                            [
                                "network",
                                "requests",
                                "-s",
                                "emulator-5554",
                                "-n",
                                "snapo_network_42",
                                "--json",
                            ]
                        )
        self.assertEqual(code, 0)
        self.assertTrue(output.closed)
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))


if __name__ == "__main__":
    unittest.main()
