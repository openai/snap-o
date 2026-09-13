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


REPOSITORY = pathlib.Path(__file__).resolve().parents[4]
SCRIPT = REPOSITORY / "skills" / "snap-o-network-inspector" / "scripts" / "snapo-network"
LOADER = importlib.machinery.SourceFileLoader("snapo_network_cli", str(SCRIPT))
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
        self.protocol_requests = []
        self.protocol_version = 4
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
                if path == "/network/protocol":
                    self.protocol_requests.append(path)
                    payload = json.dumps({"version": self.protocol_version}).encode()
                    stream.write(f"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\n\r\n".encode() + payload)
                elif path == "/network" and b"Accept: application/x-ndjson\r\n" in head:
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

    def test_idle_stream_survives_a_delayed_heartbeat(self):
        message = {"method": "Network.loadingFinished", "snapoSequence": 1}

        def handler(stream, _):
            # Allow one second of scheduling delay beyond the server's 30-second heartbeat.
            if wire.stopping.wait(31):
                return
            heartbeat = b": keep-alive\n\n"
            stream.write(f"{len(heartbeat):x}\r\n".encode() + heartbeat + b"\r\n")
            write_message(stream, message)

        with WireServer(handler) as wire:
            stream = snapo.NetworkSSE(
                lambda timeout: snapo.LocalAbstractSocket(port=wire.port, timeout=timeout), "/network"
            )
            try:
                self.assertEqual(stream.read_event()["data"], message)
            finally:
                stream.close()

    def test_partial_and_invalid_events_fail(self):
        for payload in (b'data: {}\n', b'data: "\xff"\n\n', b'data: nope\n\n'):
            with self.subTest(payload=payload), self.assertRaises(snapo.SnapOError):
                self.decoder(payload).read_event()

    def test_event_size_is_bounded(self):
        with mock.patch.object(snapo, "MAX_RECORD_BYTES", 4):
            with self.assertRaisesRegex(snapo.SnapOError, "too large"):
                self.decoder(b'data: 12345\n\n').read_event()


class FakeADB:
    has_explicit_endpoint = False

    def __init__(self, forward_port=27185):
        self.forward_port = forward_port
        self.calls = []
        self.metadata_calls = []
        self.process_name = "com.example"
        self.package_name = "com.example"

    def devices(self):
        return ["emulator-5554"]

    def sockets(self, serial, prefix=snapo.SOCKET_PREFIX):
        return ["snapo_network_42"]

    def process_info(self, server):
        self.metadata_calls.append(server)
        return {"uid": 10042, "processName": self.process_name, "startTime": "123"}

    def packages_for_uid(self, serial, uid):
        return [self.package_name]

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
        self.assertEqual(SCRIPT.parent, skills_root / "snap-o-network-inspector" / "scripts")
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
                kind = "tweaks" if name == "snap-o-tweaks" else "network"
                relative_cli = f"scripts/snapo-{kind}"
                self.assertIn(relative_cli, skill_content)
                self.assertTrue((skill_path.parent / relative_cli).resolve().is_file())
                self.assertTrue(agent_path.is_file())

                agent_metadata = agent_path.read_text(encoding="utf-8")
                self.assertIn("interface:\n", agent_metadata)
                self.assertIn(f'display_name: "{display_name}"', agent_metadata)
                self.assertIn("short_description:", agent_metadata)
                self.assertIn(f"${name}", agent_metadata)

    def test_tweaks_skill_has_its_own_cli_and_protocol_references(self):
        skill_root = REPOSITORY / "skills" / "snap-o-tweaks"
        skill_content = (skill_root / "SKILL.md").read_text(encoding="utf-8")
        tool_cli = "scripts/snapo-tweaks"

        self.assertIn(tool_cli, skill_content)
        self.assertEqual((skill_root / tool_cli).resolve(), REPOSITORY / "skills/snap-o-tweaks/scripts/snapo-tweaks")
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

        options = snapo.parser().parse_args(["list"])
        servers = snapo.discover(PartiallyUnavailableADB(), options)
        self.assertEqual(servers, [snapo.Server("emulator-5554", "snapo_network_42")])


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
        options = snapo.parser().parse_args(["list"])
        self.assertIsNone(options.adb_host)
        self.assertIsNone(options.adb_port)

    def test_parser_requires_both_explicit_adb_endpoint_options(self):
        commands = (
            ["list"],
            ["requests"],
            ["show", "--request-id", "request-1"],
        )
        incomplete_options = (
            ["--adb-host", "adb.example.test"],
            ["--adb-port", "15037"],
        )
        for command in commands:
            for endpoint in incomplete_options:
                with self.subTest(command=command[0], endpoint=endpoint[0]):
                    errors = io.StringIO()
                    with contextlib.redirect_stderr(errors):
                        with self.assertRaises(SystemExit) as error:
                            snapo.parser().parse_args(command + endpoint)
                    self.assertEqual(error.exception.code, 2)
                    self.assertIn("--adb-host and --adb-port must be used together", errors.getvalue())

    def test_parser_accepts_complete_explicit_adb_endpoint(self):
        options = snapo.parser().parse_args(
            ["list", "--adb-host", "adb.example.test", "--adb-port", "15037"]
        )
        self.assertEqual(options.adb_host, "adb.example.test")
        self.assertEqual(options.adb_port, 15037)

    def test_parser_accepts_exclusion_first_filters(self):
        for value in ("-private", "-private other", '-"private path"'):
            with self.subTest(value=value):
                options = snapo.parser().parse_args(
                    ["requests", "--filter", value, "--json"]
                )
                self.assertEqual(options.filter, value)
                self.assertTrue(options.json)

    def test_parser_preserves_missing_filter_value_errors(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                snapo.parser().parse_args(["requests", "--filter", "--json"])

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
            with mock.patch.object(snapo, "Session", return_value=session), mock.patch.object(snapo, "check_protocol"):
                with self.assertRaisesRegex(RuntimeError, "close failed"):
                    with snapo.ConnectedSession(adb, server):
                        pass

        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", "tcp:27185")))


class ProtocolTests(unittest.TestCase):


    def test_commands_check_tool_protocol_before_data_requests(self):
        for kind, supported, connection_type in (
            ("network", 4, snapo.ConnectedSession),
        ):
            for version in (None, True, "4", 0, 1, supported - 1, supported + 1):
                wire = WireServer(lambda *_: self.fail("No stream expected"))
                wire.protocol_version = version
                with self.subTest(kind=kind, version=version), wire:
                    adb = FakeADB(forward_port=wire.port)
                    with self.assertRaisesRegex(snapo.SnapOError, "Unsupported .* Tool protocol"):
                        with connection_type(adb, snapo.Server("phone", f"snapo_{kind}_42")):
                            self.fail("unsupported connection opened")
                    self.assertEqual(wire.protocol_requests, [f"/{kind}/protocol"])
                    self.assertEqual(wire.http_requests if kind == "network" else wire.requests, [])
                    self.assertEqual(adb.calls[-1], ("phone", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_missing_protocol_endpoint_is_rejected(self):
        for kind, version, connection_type in (
            ("network", 4, snapo.ConnectedSession),
        ):
            adb = FakeADB()
            with self.subTest(kind=kind), mock.patch.object(
                snapo, "HTTPResponse", side_effect=snapo.HTTPError(404, "Unknown endpoint")
            ):
                with self.assertRaisesRegex(snapo.SnapOError, "Cannot check .* Tool protocol"):
                    with connection_type(adb, snapo.Server("phone", f"snapo_{kind}_42")):
                        self.fail("missing endpoint accepted")
                self.assertEqual(adb.calls[-1], ("phone", ("forward", "--remove", "tcp:27185")))

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
            server = snapo.Server("emulator-5554", "snapo_network_42")
            with snapo.ServerConnection(adb, server) as connection:
                info = snapo.check_protocol(connection.open_socket)
        self.assertIsNone(info)
        self.assertEqual(adb.metadata_calls, [])
        self.assertEqual(wire.http_requests, [])
        self.assertEqual(wire.received, [])
        self.assertEqual(wire.protocol_requests, ["/network/protocol"])

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
            with snapo.ConnectedSession(adb, snapo.Server("emulator-5554", "snapo_network_42")) as session:
                session.start_stream()
                self.assertIsNone(session.read(1))
        self.assertEqual(wire.received, ["host:transport:emulator-5554", "localabstract:snapo_network_42"] * 3)

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
        options = snapo.parser().parse_args(["requests", "--no-stream", "--json"])
        with mock.patch.object(snapo.time, "monotonic", side_effect=lambda: clock["now"]):
            with mock.patch.object(snapo, "discover", return_value=[server]):
                with mock.patch.object(snapo, "NetworkHistory", return_value=history), mock.patch.object(snapo, "check_protocol"):
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


class NetworkDiscoveryTests(unittest.TestCase):
    def test_network_discovery_does_not_include_tweak_protocol_version(self):
        options = snapo.parser().parse_args(["list", "--no-app-info", "--json"])
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = snapo.run_list(FakeADB(), options)

        self.assertEqual(result, 0)
        self.assertNotIn("protocolVersion", json.loads(output.getvalue()))


class ProcessDiscoveryTests(unittest.TestCase):
    def output(self, name="com.example:worker", uid=1010042, start="123"):
        return f"Name:\tworker\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n42 (worker (busy)) S " + "0 " * 18 + start + "\n" + name + "\0"

    def test_reads_process_identity_and_maps_uid_without_tool_connections(self):
        replies = [self.output(), "package:com.example uid:1010042\npackage:com.other uid:10042\n", self.output()]
        run = mock.Mock(side_effect=[subprocess.CompletedProcess([], 0, output, "") for output in replies])
        adb = snapo.ADB("/configured/adb", run=run)
        server = snapo.Server("phone", snapo.SOCKET_PREFIX + "42")
        self.assertEqual(snapo.read_app_info(adb, [server])[server], {
            "packageName": "com.example", "processName": "com.example:worker",
        })
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands[0], ["/configured/adb", "-s", "phone", "shell", "cat /proc/42/status /proc/42/stat /proc/42/cmdline"])
        self.assertEqual(commands[1], ["/configured/adb", "-s", "phone", "shell", "cmd package list packages -U --user 10"])
        self.assertEqual(commands[2], commands[0])

    def test_malformed_process_metadata_is_rejected(self):
        for output in ("", self.output(start="bad"), self.output(name=""), self.output(name="bad\nname"), "x" * 65537):
            with self.subTest(output=output[:30]), self.assertRaises(snapo.SnapOError):
                snapo.parse_process_info(output, 42)

    def test_packages_are_deduplicated_and_filtered_by_uid(self):
        output = "package:com.example uid:10042\npackage:com.other uid:10043\npackage:com.example uid:10042\nmalformed\n"
        run = mock.Mock(return_value=subprocess.CompletedProcess([], 0, output, ""))
        self.assertEqual(snapo.ADB("adb", run=run).packages_for_uid("phone", 10042), ["com.example"])

    def test_process_name_is_only_a_hint_with_verified_uid_ownership(self):
        server = snapo.Server("phone", snapo.SOCKET_PREFIX + "42")
        adb = FakeADB()
        adb.process_name = "com.unrelated:worker"
        self.assertEqual(snapo.read_app_info(adb, [server])[server]["packageName"], "com.example")
        adb.packages_for_uid = mock.Mock(return_value=["com.one", "com.two"])
        self.assertIsNone(snapo.read_app_info(adb, [server])[server]["packageName"])
        adb.process_name = "com.two:worker"
        self.assertEqual(snapo.read_app_info(adb, [server])[server]["packageName"], "com.two")

    def test_exited_or_replaced_process_does_not_hide_other_sockets(self):
        servers = [snapo.Server("phone", snapo.SOCKET_PREFIX + str(pid)) for pid in (41, 42, 43)]
        adb = FakeADB()
        stable = {"uid": 10042, "processName": "com.example", "startTime": "123"}
        adb.process_info = mock.Mock(side_effect=[
            snapo.SnapOError("process exited"), stable, {**stable, "startTime": "124"}, stable, stable,
        ])
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            apps = snapo.read_app_info(adb, servers)
        self.assertEqual(apps[servers[0]], {})
        self.assertEqual(apps[servers[1]], {})
        self.assertEqual(apps[servers[2]]["packageName"], "com.example")
        self.assertIn("process exited", errors.getvalue())
        self.assertIn("Process changed", errors.getvalue())

    def test_package_queries_are_cached_by_device_and_uid(self):
        adb = FakeADB()
        adb.packages_for_uid = mock.Mock(return_value=["com.example"])
        servers = [snapo.Server(device, snapo.SOCKET_PREFIX + str(pid)) for device, pid in (("phone", 41), ("phone", 42), ("tablet", 42))]
        snapo.read_app_info(adb, servers)
        self.assertEqual(adb.packages_for_uid.call_args_list, [mock.call("phone", 10042), mock.call("tablet", 10042)])


class StandaloneInstallationTests(unittest.TestCase):
    def test_copied_cli_discovers_an_app_with_only_adb(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            script = root / SCRIPT.name
            script.write_bytes(SCRIPT.read_bytes())
            script.chmod(0o755)
            adb = root / "adb"
            process = ProcessDiscoveryTests().output(uid=10042)
            adb.write_text(
                "#!/usr/bin/env python3\nimport sys\n"
                "args = sys.argv[1:]\n"
                "if args[:1] == ['-s']: args = args[2:]\n"
                "if args == ['devices', '-l']: print('phone device')\n"
                f"elif args == ['shell', 'cat /proc/net/unix']: print('1: 0 0 00010000 0001 01 1 @{snapo.SOCKET_PREFIX}42')\n"
                f"elif args == ['shell', 'cat /proc/42/status /proc/42/stat /proc/42/cmdline']: sys.stdout.write({process!r})\n"
                "elif args == ['shell', 'cmd package list packages -U --user 0']: print('package:com.example uid:10042')\n"
                "else: raise SystemExit('Unexpected ADB command: ' + repr(args))\n"
            )
            adb.chmod(0o755)
            result = subprocess.run(
                [str(script), "list", "--json", "--adb", str(adb)],
                cwd=directory, capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertEqual(json.loads(result.stdout), {
                "server": f"phone/{snapo.SOCKET_PREFIX}42", "deviceId": "phone",
                "socketName": f"{snapo.SOCKET_PREFIX}42", "pid": 42,
                "packageName": "com.example", "processName": "com.example:worker",
            })

    def test_copied_cli_has_only_its_own_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            script = pathlib.Path(directory) / SCRIPT.name
            script.write_bytes(SCRIPT.read_bytes())
            script.chmod(0o755)
            command = [sys.executable, "-I", str(script)]
            result = subprocess.run([*command, "--help"], cwd=directory, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(SCRIPT.name, result.stdout)
            self.assertIn("intercept", result.stdout)
            self.assertNotIn("watch", result.stdout)
            for arguments in (["watch"], ["network", "list"]):
                with self.subTest(arguments=arguments):
                    result = subprocess.run([*command, *arguments], cwd=directory, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("invalid choice", result.stderr)


if __name__ == "__main__":
    unittest.main()
