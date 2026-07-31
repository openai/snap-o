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
import tempfile
import threading
import unittest
from unittest import mock


REPOSITORY = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts" / "snapo"
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
    def __init__(self, handler, adb_handshake=False):
        self.handler = handler
        self.adb_handshake = adb_handshake
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
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
        self.listener.close()
        if error_type is not None:
            return
        if self.failure:
            raise self.failure
        if self.thread.is_alive():
            raise AssertionError("wire server did not stop")

    def run(self):
        try:
            connection, _ = self.listener.accept()
            with connection:
                if self.stopping.is_set():
                    return
                connection.settimeout(2)
                stream = connection.makefile("rwb", buffering=0)
                if self.adb_handshake:
                    for _ in range(2):
                        length = int(stream.read(4), 16)
                        self.received.append(stream.read(length).decode("utf-8"))
                        stream.write(b"OKAY")
                hello = stream.readline()
                self.received.append(hello.decode("utf-8").rstrip())
                self.handler(stream, self.received)
        except Exception as error:
            self.failure = error


def read_message(stream, received):
    value = json.loads(stream.readline())
    received.append(value)
    return value


def write_message(stream, value):
    stream.write(json.dumps(value, separators=(",", ":")).encode("utf-8") + b"\n")


class FakeADB:
    def __init__(self, fail_forward=False):
        self.fail_forward = fail_forward
        self.calls = []

    def devices(self):
        return ["emulator-5554"]

    def sockets(self, serial):
        return ["snapo_network_42"]

    def package_hint(self, server):
        return "com.example.app"

    def command(self, *arguments, serial=None):
        self.calls.append((serial, arguments))
        if arguments and arguments[0] == "forward" and "--remove" not in arguments and self.fail_forward:
            self.fail_forward = False
            raise snapo.SnapOError("port in use")
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
    def __init__(self, sockets=None, devices=None, fail_forward=False):
        super().__init__(fail_forward=fail_forward)
        self.available_devices = devices or ["emulator-5554"]
        self.available_sockets = sockets or {"emulator-5554": ["snapo_tweaks_42"]}

    def devices(self):
        return self.available_devices

    def tweak_sockets(self, serial):
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
        {"name": "Palette/Accent color", "type": "color", "default": "#5468FF", "value": "#5468FF"},
        {"name": "Preview/Text value", "type": "string", "default": "true", "value": "true"},
    ]


class TweakHTTPServer:
    def __init__(self, descriptors=None, app=None, error=None, stream_events=None, adjusted_descriptors=None):
        self.descriptors = json.loads(json.dumps(descriptors or tweak_descriptors()))
        self.adjusted_descriptors = self.descriptors if adjusted_descriptors is None else adjusted_descriptors
        self.app = app or {"name": "Snap-O Tweaks Demo", "packageName": "com.example.tweaks"}
        self.error = error
        self.stream_events = stream_events
        self.requests = []
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                owner.requests.append(("GET", self.path, None))
                if self.path == "/app":
                    self.send_json(200, owner.app)
                elif self.path == "/tweaks":
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
                unknown = next((name for name in payload["values"] if name not in descriptors), None)
                if unknown is not None:
                    self.send_json(404, {"error": f"Unknown tweak: {unknown}"})
                    return

                updates = []
                for name, value in payload["values"].items():
                    if descriptors[name]["type"] == "color":
                        value = value.upper()
                    descriptors[name]["value"] = value
                    updates.append({"name": name, "value": value})
                self.send_json(200, {"tweaks": updates})

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
        self.assertEqual(SCRIPT.parent, REPOSITORY / "scripts")
        self.assertTrue(SCRIPT.is_file())
        self.assertTrue(os.access(SCRIPT, os.X_OK))
        self.assertEqual(manifest["interface"]["displayName"], "Snap-O")
        self.assertEqual(manifest["interface"]["capabilities"], ["Read", "Write"])

        for name, display_name in (
            ("snap-o-network-inspector", "Snap-O Network Inspector"),
            ("snap-o-tweaks", "Snap-O Tweaks"),
        ):
            with self.subTest(skill=name):
                skill_path = skills_root / name / "SKILL.md"
                agent_path = skills_root / name / "agents" / "openai.yaml"

                self.assertTrue(skill_path.is_file())
                skill_content = skill_path.read_text(encoding="utf-8")
                self.assertIn(f"\nname: {name}\n", skill_content)
                self.assertIn("../../scripts/snapo", skill_content)
                self.assertEqual((skill_path.parent / "../../scripts/snapo").resolve(), SCRIPT)
                self.assertTrue(agent_path.is_file())

                agent_metadata = agent_path.read_text(encoding="utf-8")
                self.assertIn("interface:\n", agent_metadata)
                self.assertIn(f'display_name: "{display_name}"', agent_metadata)
                self.assertIn("short_description:", agent_metadata)
                self.assertIn(f"${name}", agent_metadata)

    def test_tweaks_skill_reuses_shared_cli_and_bundles_protocol_references(self):
        skill_root = REPOSITORY / "skills" / "snap-o-tweaks"
        skill_content = (skill_root / "SKILL.md").read_text(encoding="utf-8")
        shared_cli = "../../scripts/snapo"

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

    def test_documented_marketplace_install_avoids_sparse_paths_and_migrates_existing_users(self):
        readme = (REPOSITORY / "README.md").read_text(encoding="utf-8")
        add_command = "codex plugin marketplace add openai/snap-o --ref main"
        install_command = "codex plugin add snap-o@snap-o"
        add_commands = [line.strip() for line in readme.splitlines() if line.strip().startswith(add_command)]

        self.assertGreaterEqual(len(add_commands), 2)
        self.assertTrue(all(command == add_command for command in add_commands))
        self.assertNotIn("--sparse", readme)

        migration_start = readme.index("codex plugin marketplace remove snap-o")
        migration_add = readme.index(add_command, migration_start)
        migration_install = readme.index(install_command, migration_add)
        self.assertLess(migration_start, migration_add)
        self.assertLess(migration_add, migration_install)
        self.assertIn("codex plugin marketplace upgrade snap-o", readme[migration_install:])


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
1: 0 0 0 1 01 1 @snapo_network_42
2: 0 0 0 1 01 2 @unrelated
3: 0 0 0 1 01 3 @snapo_network_7
4: 0 0 0 1 01 4 @snapo_network_42
"""
        )
        self.assertEqual(devices, ["emulator-5554", "usb-phone"])
        self.assertEqual(sockets, ["snapo_network_42", "snapo_network_7"])

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

            def sockets(self, serial):
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

    def test_parses_tweak_sockets_without_mixing_network_inspectors(self):
        output = """Num RefCount Protocol Flags Type St Inode Path
1: 0 0 0 1 01 1 @snapo_network_42
2: 0 0 0 1 01 2 @snapo_tweaks_93
3: 0 0 0 1 01 3 @unrelated
4: 0 0 0 1 01 4 @snapo_tweaks_7
5: 0 0 0 1 01 5 @snapo_tweaks_93
"""
        self.assertEqual(snapo.parse_tweak_sockets(output), ["snapo_tweaks_7", "snapo_tweaks_93"])
        self.assertEqual(snapo.parse_sockets(output), ["snapo_network_42"])

    def test_adb_tweak_socket_discovery_reads_device_unix_sockets(self):
        recorded = []

        def run(command, **kwargs):
            recorded.append(command)
            output = "1: 0 0 0 1 01 1 @snapo_tweaks_42\n2: 0 0 0 1 01 2 @snapo_network_9\n"
            return type("Result", (), {"returncode": 0, "stdout": output, "stderr": ""})()

        adb = snapo.ADB("/configured/adb", run=run)
        self.assertEqual(adb.tweak_sockets("emulator-5554"), ["snapo_tweaks_42"])
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
            snapo.discover_tweaks(adb, options),
            [snapo.Server("emulator-5554", "snapo_tweaks_42"), snapo.Server("usb-phone", "snapo_tweaks_8")],
        )

        selected = snapo.parser().parse_args(["tweaks", "apps", "-s", "usb-phone"])
        self.assertEqual(snapo.discover_tweaks(adb, selected), [snapo.Server("usb-phone", "snapo_tweaks_8")])

    def test_parser_registers_every_tweak_command_and_shared_selectors(self):
        commands = {
            "apps": ["apps"],
            "list": ["list", "-n", "snapo_tweaks_42"],
            "get": ["get", "Typography/Font size", "-n", "snapo_tweaks_42"],
            "set": ["set", "Typography/Font size", "-2", "-n", "snapo_tweaks_42"],
            "reset": ["reset", "Typography/Font size", "-n", "snapo_tweaks_42"],
            "watch": ["watch", "--once", "-n", "snapo_tweaks_42"],
        }
        for name, arguments in commands.items():
            with self.subTest(command=name):
                options = snapo.parser().parse_args(
                    ["tweaks", *arguments, "-s", "emulator-5554", "--adb", "/configured/adb", "--json"]
                )
                self.assertEqual(options.root_command, "tweaks")
                self.assertEqual(options.tweaks_command, name)
                self.assertEqual(options.serial, "emulator-5554")
                self.assertEqual(options.adb, "/configured/adb")
                self.assertTrue(options.json)

    def test_tweak_commands_preserve_remote_adb_endpoint_validation(self):
        commands = (
            ["tweaks", "apps"],
            ["tweaks", "list"],
            ["tweaks", "get", "Motion/Enabled"],
            ["tweaks", "set", "Motion/Enabled", "false"],
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

    def test_float_json_values_reject_huge_integers_without_overflowing(self):
        descriptor = self.descriptor("Motion/Damping ratio")
        with self.assertRaises(snapo.SnapOError):
            snapo.validate_tweak_json_value(descriptor, 10**400)

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


class ADBTests(unittest.TestCase):
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

    def test_forward_retries_and_removes_only_its_forward(self):
        adb = FakeADB(fail_forward=True)
        server = snapo.Server("emulator-5554", "snapo_network_42")
        with mock.patch.object(snapo, "available_port", side_effect=[27185, 27186]):
            with snapo.Forward(adb, server) as forward:
                self.assertEqual(forward.port, 27186)
        self.assertEqual(
            adb.calls,
            [
                ("emulator-5554", ("forward", "tcp:27185", "localabstract:snapo_network_42")),
                ("emulator-5554", ("forward", "tcp:27186", "localabstract:snapo_network_42")),
                ("emulator-5554", ("forward", "--remove", "tcp:27186")),
            ],
        )

    def test_forward_is_removed_when_session_work_fails(self):
        adb = FakeADB()
        server = snapo.Server("emulator-5554", "snapo_network_42")
        with mock.patch.object(snapo, "available_port", return_value=27185):
            with self.assertRaisesRegex(RuntimeError, "expected"):
                with snapo.Forward(adb, server):
                    raise RuntimeError("expected")
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", "tcp:27185")))


class ProtocolTests(unittest.TestCase):
    def test_shared_http_replay_fixture_terminates_with_replay_complete(self):
        fixture = REPOSITORY / "contracts" / "network" / "v1" / "http-replay.jsonl"
        records = [json.loads(line) for line in fixture.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(records[0]["method"], "SnapO.appInfo")
        self.assertEqual(records[-1]["method"], "SnapO.replayComplete")
        self.assertEqual(records[-1]["params"]["watermark"], 3)

    def test_handshake_start_stream_and_replay_completion(self):
        def handler(stream, received):
            started = read_message(stream, received)
            self.assertEqual(started, {"method": "SnapO.startStream"})
            write_message(stream, {"method": "SnapO.appInfo", "params": {"packageName": "com.example"}})
            write_message(stream, {"method": "SnapO.replayComplete", "params": {"watermark": 3}})

        with WireServer(handler) as server:
            session = snapo.Session(server.port)
            try:
                session.start_stream()
                self.assertEqual(session.read(1)["method"], "SnapO.appInfo")
                self.assertEqual(session.read(1)["method"], "SnapO.replayComplete")
            finally:
                session.close()
        self.assertEqual(server.received[0], "HelloSnapO")

    def test_explicit_adb_endpoint_uses_direct_smart_socket_transport(self):
        def handler(stream, received):
            started = read_message(stream, received)
            self.assertEqual(started, {"method": "SnapO.startStream"})
            write_message(stream, {"method": "SnapO.replayComplete", "params": {"watermark": 0}})

        with WireServer(handler, adb_handshake=True) as wire:
            adb = snapo.ADB("/configured/adb", host="127.0.0.1", port=wire.port)
            server = snapo.Server("emulator-5554", "snapo_network_42")
            with snapo.ConnectedSession(adb, server) as session:
                session.start_stream()
                self.assertEqual(session.read(1)["method"], "SnapO.replayComplete")
        self.assertEqual(
            wire.received[:3],
            [
                "host:transport:emulator-5554",
                "localabstract:snapo_network_42",
                "HelloSnapO",
            ],
        )

    def test_ignores_valid_json_records_that_are_not_objects(self):
        def handler(stream, received):
            stream.write(b"null\n[]\n42\n\"text\"\n")
            write_message(stream, {"method": "SnapO.replayComplete", "params": {"watermark": 0}})

        with WireServer(handler) as wire:
            session = snapo.Session(wire.port)
            try:
                self.assertEqual(session.read(1)["method"], "SnapO.replayComplete")
            finally:
                session.close()

    def test_ignores_malformed_protocol_record_shapes(self):
        malformed = [
            {"method": [], "params": {}},
            {"method": "Network.loadingFinished", "params": "invalid"},
            {"method": "Network.loadingFinished", "params": []},
            {"method": "Network.requestWillBeSent", "params": {"request": "invalid"}},
            {"method": "Network.requestWillBeSent", "params": {"request": {"headers": "invalid"}}},
            {"method": "Network.requestWillBeSent", "params": {"request": {"method": 7}}},
            {"method": "Network.requestWillBeSent", "params": {"request": {"url": {"invalid": True}}}},
            {"method": "Network.requestWillBeSent", "params": {"request": {"postDataEncoding": 7}}},
            {"method": "Network.requestWillBeSent", "params": {"request": {"hasPostData": "yes"}}},
            {"method": "Network.responseReceived", "params": {"response": []}},
            {"method": "Network.responseReceived", "params": {"response": {"headers": []}}},
            {"method": "Network.responseReceived", "params": {"response": {"url": {"invalid": True}}}},
            {"method": "Network.responseReceived", "params": {"response": {"status": float("inf")}}},
            {"method": "Network.responseReceived", "params": {"response": {"status": float("nan")}}},
            {"method": "Network.responseReceived", "params": {"response": {"status": True}}},
            {"method": "Network.webSocketCreated", "params": {"headers": "invalid"}},
            {"id": 1, "result": "invalid"},
            {"id": 1, "error": "invalid"},
        ]

        def handler(stream, received):
            for message in malformed:
                write_message(stream, message)
            write_message(stream, {"method": "SnapO.replayComplete", "params": {"watermark": 0}})

        with WireServer(handler) as wire:
            session = snapo.Session(wire.port)
            try:
                self.assertEqual(session.read(1)["method"], "SnapO.replayComplete")
            finally:
                session.close()

    def test_rejects_oversized_terminated_record(self):
        def handler(stream, received):
            stream.write(b'{"oversized":true}\n')

        with WireServer(handler) as wire:
            session = snapo.Session(wire.port)
            try:
                with mock.patch.object(snapo, "MAX_RECORD_BYTES", 8):
                    with self.assertRaisesRegex(snapo.SnapOError, "oversized"):
                        session.read(1)
            finally:
                session.close()

    def test_command_ignores_unrelated_id_and_correlates_response(self):
        observed = []

        def handler(stream, received):
            command = read_message(stream, received)
            write_message(stream, {"id": command["id"] + 10, "result": {"body": "unrelated"}})
            write_message(stream, {"method": "Network.loadingFinished", "params": {"requestId": "other"}})
            write_message(stream, {"id": command["id"], "result": {"body": "expected"}})

        with WireServer(handler) as server:
            session = snapo.Session(server.port)
            try:
                reply = session.command(
                    "Network.getResponseBody",
                    {"requestId": "request-1"},
                    timeout=1,
                    on_event=observed.append,
                )
            finally:
                session.close()
        self.assertEqual(reply["result"]["body"], "expected")
        self.assertEqual(len(observed), 2)
        self.assertEqual(server.received[1]["method"], "Network.getResponseBody")

    def test_command_timeout_is_reported(self):
        def handler(stream, received):
            read_message(stream, received)
            threading.Event().wait(0.12)

        with WireServer(handler) as server:
            session = snapo.Session(server.port)
            try:
                with self.assertRaisesRegex(snapo.SnapOError, "Timed out waiting"):
                    session.command("Network.getResponseBody", {"requestId": "request-1"}, timeout=0.03)
            finally:
                session.close()

    def test_fetches_both_bodies_and_redacts_headers(self):
        def handler(stream, received):
            started = read_message(stream, received)
            self.assertEqual(started["method"], "SnapO.startStream")
            write_message(stream, request_event())
            write_message(stream, response_event())
            write_message(stream, {"method": "Network.loadingFinished", "params": {"requestId": "request-1"}})
            request_command = read_message(stream, received)
            write_message(stream, {"id": request_command["id"], "result": {"postData": '{"hello":"world"}'}})
            response_command = read_message(stream, received)
            write_message(
                stream,
                {"id": response_command["id"], "result": {"body": '{"ok":true}', "base64Encoded": False}},
            )

        with WireServer(handler) as wire:
            session = snapo.Session(wire.port)
            try:
                details = snapo.request_details(
                    session,
                    snapo.Server("emulator-5554", "snapo_network_42"),
                    "request-1",
                )
            finally:
                session.close()
        self.assertEqual(details["requestBody"], '{"hello":"world"}')
        self.assertEqual(details["responseBody"], '{"ok":true}')
        self.assertFalse(details["responseBodyBase64Encoded"])
        self.assertEqual(details["requestHeaders"]["Authorization"], snapo.REDACTED)
        self.assertEqual(details["requestHeaders"]["Cookie"], snapo.REDACTED)
        self.assertEqual(details["responseHeaders"]["Set-Cookie"], snapo.REDACTED)
        self.assertEqual(
            [message["method"] for message in wire.received[2:]],
            ["Network.getRequestPostData", "Network.getResponseBody"],
        )

    def test_zero_padded_content_length_skips_response_body_lookup(self):
        def handler(stream, received):
            read_message(stream, received)
            request = request_event()
            request["params"]["request"]["hasPostData"] = False
            response = response_event()
            response["params"]["response"]["headers"]["Content-Length"] = "00"
            write_message(stream, request)
            write_message(stream, response)
            write_message(stream, {"method": "Network.loadingFinished", "params": {"requestId": "request-1"}})

        with WireServer(handler) as wire:
            session = snapo.Session(wire.port)
            try:
                details = snapo.request_details(
                    session,
                    snapo.Server("emulator-5554", "snapo_network_42"),
                    "request-1",
                )
            finally:
                session.close()

        self.assertEqual(details["responseBody"], "")
        self.assertFalse(details["responseBodyBase64Encoded"])
        self.assertEqual([message["method"] for message in wire.received[1:]], ["SnapO.startStream"])

    def test_uncaptured_empty_response_body_does_not_hide_response_details(self):
        def handler(stream, received):
            read_message(stream, received)
            request = request_event()
            request["params"]["request"]["hasPostData"] = False
            write_message(stream, request)
            write_message(stream, response_event())
            write_message(stream, {"method": "Network.loadingFinished", "params": {"requestId": "request-1"}})
            command = read_message(stream, received)
            write_message(
                stream,
                {"id": command["id"], "error": {"message": "No response body captured for request-1"}},
            )

        with WireServer(handler) as wire:
            session = snapo.Session(wire.port)
            try:
                details = snapo.request_details(
                    session,
                    snapo.Server("emulator-5554", "snapo_network_42"),
                    "request-1",
                )
            finally:
                session.close()

        self.assertEqual(details["responseStatus"], 200)
        self.assertEqual(details["responseBody"], "")
        self.assertFalse(details["responseBodyBase64Encoded"])

    def test_request_details_keeps_waiting_while_replay_is_active(self):
        clock = {"now": 0}
        request = request_event()
        request["params"]["request"]["hasPostData"] = False

        class SlowReplaySession:
            def __init__(self):
                self.messages = [
                    {"method": "SnapO.appInfo", "params": {}},
                    {"method": "SnapO.appInfo", "params": {}},
                    {"method": "SnapO.appInfo", "params": {}},
                    request,
                    response_event(),
                    {"method": "Network.loadingFinished", "params": {"requestId": "request-1"}},
                ]

            def start_stream(self):
                return None

            def read(self, timeout):
                clock["now"] += 2
                return self.messages.pop(0)

            def command(self, method, params, timeout, on_event):
                return {"result": {"body": "", "base64Encoded": False}}

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
                    return {"method": "SnapO.replayComplete", "params": {"watermark": 0}}
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
            with mock.patch.object(snapo, "available_port", return_value=wire.port):
                with snapo.TweakConnection(adb, server) as connection:
                    response = connection.request("GET", "/tweaks")

        self.assertEqual(response["tweaks"][0]["name"], "Typography/Font size")
        self.assertEqual(
            adb.calls,
            [
                ("emulator-5554", ("forward", f"tcp:{wire.port}", "localabstract:snapo_tweaks_42")),
                ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")),
            ],
        )

    def test_explicit_adb_endpoint_sends_http_through_direct_smart_socket(self):
        payload = {"tweaks": tweak_descriptors()}
        with TweakSmartSocketServer(payload) as wire:
            adb = snapo.ADB("/configured/adb", host="127.0.0.1", port=wire.port)
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
        self.assertNotIn("HelloSnapO", " ".join(wire.received))

    def test_http_errors_include_status_and_server_message(self):
        adb = FakeTweakADB()
        server = snapo.Server("emulator-5554", "snapo_tweaks_42")
        for status, detail in ((404, "Unknown tweak: Missing"), (422, "Value exceeds the maximum.")):
            with self.subTest(status=status):
                with TweakHTTPServer(error=(status, detail)) as wire:
                    with mock.patch.object(snapo, "available_port", return_value=wire.port):
                        with snapo.TweakConnection(adb, server) as connection:
                            with self.assertRaisesRegex(snapo.SnapOError, f"HTTP {status}.*{detail}"):
                                connection.request("PATCH", "/tweaks", {"values": {"Motion/Enabled": False}})

                self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_oversized_http_responses_are_rejected_and_forward_is_removed(self):
        adb = FakeTweakADB()
        server = snapo.Server("emulator-5554", "snapo_tweaks_42")
        with TweakHTTPServer() as wire:
            with mock.patch.object(snapo, "available_port", return_value=wire.port):
                with mock.patch.object(snapo, "MAX_RECORD_BYTES", 16):
                    with self.assertRaisesRegex(snapo.SnapOError, "oversized"):
                        with snapo.TweakConnection(adb, server) as connection:
                            connection.request("GET", "/tweaks")

        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))


class TweakCommandTests(unittest.TestCase):
    def run_command(self, arguments, wire, adb=None):
        adb = adb or FakeTweakADB()
        stdout = io.StringIO()
        stderr = io.StringIO()
        with mock.patch.object(snapo, "resolve_adb", return_value="/configured/adb"):
            with mock.patch.object(snapo, "ADB", return_value=adb):
                with mock.patch.object(snapo, "available_port", return_value=wire.port):
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
        self.assertEqual(wire.requests, [("GET", "/app", None)])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_list_emits_one_complete_json_snapshot(self):
        with TweakHTTPServer() as wire:
            result, output, errors, adb = self.run_command(["list", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), {"tweaks": wire.descriptors})
        self.assertEqual(wire.requests, [("GET", "/tweaks", None)])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_list_all_includes_previously_adjusted_inactive_tweaks(self):
        active = tweak_descriptors()[0]
        inactive = {**tweak_descriptors()[1], "name": "Motion/Historical duration", "value": 0.7}

        with TweakHTTPServer(descriptors=[active], adjusted_descriptors=[active, inactive]) as wire:
            result, output, errors, adb = self.run_command(["list", "--all", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), {"tweaks": [active, inactive]})
        self.assertEqual(wire.requests, [("GET", "/tweaks?include=adjusted", None)])
        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_list_all_preserves_independently_adjusted_tweaks_with_the_same_name(self):
        active = tweak_descriptors()[1]
        first = {**tweak_descriptors()[0], "value": 20}
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

    def test_get_accepts_tweak_names_with_slashes_and_spaces(self):
        with TweakHTTPServer() as wire:
            result, output, errors, _ = self.run_command(["get", "Typography/Font size", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(json.loads(output), wire.descriptors[0])
        self.assertEqual(wire.requests, [("GET", "/tweaks", None)])

    def test_get_all_finds_a_previously_adjusted_inactive_tweak(self):
        active = tweak_descriptors()[0]
        inactive = {**tweak_descriptors()[1], "name": "Motion/Historical duration", "value": 0.7}

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
        first = {**tweak_descriptors()[0], "value": 20}
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
            ("Preview/Text value", "-hello", "-hello"),
            ("Preview/Text value", "-foo", "-foo"),
            ("Preview/Text value", "--literal", "--literal"),
            ("Preview/Text value", "-h", "-h"),
            ("Preview/Text value", "--help", "--help"),
        )
        for name, raw, expected in cases:
            with self.subTest(name=name, value=raw):
                with TweakHTTPServer() as wire:
                    result, output, errors, adb = self.run_command(["set", name, raw, "--json"], wire)

                self.assertEqual(result, 0, errors)
                self.assertEqual(json.loads(output), {"tweaks": [{"name": name, "value": expected}]})
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
        )
        for name, raw in cases:
            with self.subTest(name=name, value=raw):
                with TweakHTTPServer() as wire:
                    result, output, errors, adb = self.run_command(["set", name, raw, "--json"], wire)

                self.assertEqual(result, 1)
                self.assertEqual(output, "")
                self.assertTrue(errors.startswith("snapo:"), errors)
                self.assertEqual(wire.requests, [("GET", "/tweaks", None)])
                self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_set_applies_a_typed_json_batch_in_one_atomic_patch(self):
        values = {
            "Typography/Font size": -2,
            "Motion/Damping ratio": -0.5,
            "Motion/Enabled": False,
            "Preview/Text value": "true",
        }
        with TweakHTTPServer() as wire:
            result, output, errors, _ = self.run_command(
                ["set", "--values-json", json.dumps(values), "--json"],
                wire,
            )

        self.assertEqual(result, 0, errors)
        self.assertEqual(wire.requests, [("GET", "/tweaks", None), ("PATCH", "/tweaks", {"values": values})])
        self.assertEqual(
            json.loads(output),
            {"tweaks": [{"name": name, "value": value} for name, value in values.items()]},
        )

    def test_invalid_json_batches_never_partially_update_tweaks(self):
        batches = (
            "{",
            "[]",
            "{}",
            '{"Motion/Enabled":"false"}',
            '{"Typography/Font size":true}',
            '{"Motion/Damping ratio":NaN}',
            '{"Motion/Damping ratio":' + "9" * 400 + "}",
            '{"Motion/Enabled":false,"Motion/Missing":12}',
        )
        for batch in batches:
            with self.subTest(batch=batch):
                with TweakHTTPServer() as wire:
                    result, output, errors, _ = self.run_command(
                        ["set", "--values-json", batch, "--json"],
                        wire,
                    )

                self.assertEqual(result, 1)
                self.assertEqual(output, "")
                self.assertTrue(errors.startswith("snapo:"), errors)
                self.assertEqual(wire.requests, [("GET", "/tweaks", None)])

    def test_reset_one_tweak_patches_its_declared_default(self):
        descriptors = tweak_descriptors()
        descriptors[0]["value"] = 24
        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(
                ["reset", "Typography/Font size", "--json"],
                wire,
            )

        self.assertEqual(result, 0, errors)
        self.assertEqual(wire.requests[1], ("PATCH", "/tweaks", {"values": {"Typography/Font size": 16}}))
        self.assertEqual(json.loads(output), {"tweaks": [{"name": "Typography/Font size", "value": 16}]})

    def test_reset_all_patches_every_default_in_one_atomic_request(self):
        descriptors = tweak_descriptors()
        descriptors[0]["value"] = 24
        descriptors[2]["value"] = False
        defaults = {descriptor["name"]: descriptor["default"] for descriptor in descriptors}
        with TweakHTTPServer(descriptors=descriptors) as wire:
            result, output, errors, _ = self.run_command(["reset", "--all", "--json"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(wire.requests, [("GET", "/tweaks", None), ("PATCH", "/tweaks", {"values": defaults})])
        self.assertEqual(len(json.loads(output)["tweaks"]), len(descriptors))

    def test_reset_requires_exactly_one_target(self):
        for arguments in (["reset"], ["reset", "Motion/Enabled", "--all"]):
            with self.subTest(arguments=arguments):
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    with self.assertRaises(SystemExit) as error:
                        snapo.parser().parse_args(["tweaks", *arguments])
                self.assertEqual(error.exception.code, 2)
                self.assertIn("reset requires either NAME or --all", errors.getvalue())

    def test_set_requires_either_one_value_or_an_atomic_batch(self):
        invalid = (
            ["set"],
            ["set", "Motion/Enabled"],
            ["set", "Motion/Enabled", "true", "--values-json", '{"Motion/Enabled":false}'],
        )
        for arguments in invalid:
            with self.subTest(arguments=arguments):
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    with self.assertRaises(SystemExit) as error:
                        snapo.parser().parse_args(["tweaks", *arguments])
                self.assertEqual(error.exception.code, 2)
                self.assertIn("set", errors.getvalue())

    def test_server_validation_errors_reach_stderr_and_remove_the_forward(self):
        for status, detail in ((404, "Unknown tweak: Motion/Enabled"), (422, "Value exceeds the maximum.")):
            with self.subTest(status=status):
                with TweakHTTPServer(error=(status, detail)) as wire:
                    result, output, errors, adb = self.run_command(
                        ["set", "Motion/Enabled", "false", "--json"],
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

    def test_snapshot_replay_timeout_resets_while_records_arrive(self):
        clock = {"now": 0}

        class SlowReplaySession:
            def __init__(self):
                self.messages = [
                    request_event(),
                    response_event(),
                    {"method": "Network.loadingFinished", "params": {"requestId": "request-1"}},
                    {"method": "SnapO.replayComplete", "params": {"watermark": 3}},
                ]

            def __enter__(self):
                return self

            def __exit__(self, error_type, error, traceback):
                return False

            def start_stream(self):
                return None

            def read(self, timeout):
                clock["now"] += 2
                return self.messages.pop(0)

        server = snapo.Server("emulator-5554", "snapo_network_42")
        options = snapo.parser().parse_args(["network", "requests", "--no-stream", "--json"])
        with mock.patch.object(snapo.time, "monotonic", side_effect=lambda: clock["now"]):
            with mock.patch.object(snapo, "discover", return_value=[server]):
                with mock.patch.object(snapo, "ConnectedSession", return_value=SlowReplaySession()):
                    with contextlib.redirect_stdout(io.StringIO()):
                        result = snapo.run_requests(FakeADB(), options)

        self.assertEqual(result, 0)
        self.assertGreater(clock["now"], 5)

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

    def test_filter_uses_network_inspector_search_grammar(self):
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
        def handler(stream, received):
            started = read_message(stream, received)
            self.assertEqual(started["method"], "SnapO.startStream")
            write_message(stream, request_event())
            write_message(stream, response_event())
            write_message(stream, {"method": "SnapO.replayComplete", "params": {"watermark": 2}})

        adb = FakeADB()
        stdout = io.StringIO()
        with WireServer(handler) as wire:
            with mock.patch.object(snapo, "resolve_adb", return_value="/configured/adb"):
                with mock.patch.object(snapo, "ADB", return_value=adb):
                    with mock.patch.object(snapo, "available_port", return_value=wire.port):
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
            read_message(stream, received)
            write_message(stream, request_event())

        adb = FakeADB()
        output = ClosedPipe()
        with WireServer(handler) as wire:
            with mock.patch.object(snapo, "resolve_adb", return_value="/configured/adb"):
                with mock.patch.object(snapo, "ADB", return_value=adb):
                    with mock.patch.object(snapo, "available_port", return_value=wire.port):
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
