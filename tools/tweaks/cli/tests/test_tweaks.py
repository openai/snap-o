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
SCRIPT = REPOSITORY / "skills" / "snap-o-tweaks" / "scripts" / "snapo-tweaks"
LOADER = importlib.machinery.SourceFileLoader("snapo_tweaks_cli", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
snapo = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(snapo)


REQUEST_SECRET = "request-secret-must-not-print"
COOKIE_SECRET = "cookie-secret-must-not-print"
RESPONSE_SECRET = "response-secret-must-not-print"


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


class FakeTweakADB(FakeADB):
    def __init__(self, sockets=None, devices=None, forward_port=27185):
        super().__init__(forward_port=forward_port)
        self.process_name = "com.example.tweaks"
        self.package_name = "com.example.tweaks"
        self.available_devices = devices or ["emulator-5554"]
        self.available_sockets = sockets or {"emulator-5554": ["snapo_tweaks_42"]}

    def devices(self):
        return self.available_devices

    def sockets(self, serial, prefix=snapo.SOCKET_PREFIX):
        if prefix != snapo.SOCKET_PREFIX:
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
        self.protocol_requests = []
        self.protocol_version = 8
        self.protocol_error = None
        self.protocol_content_type = "application/json"
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                if self.path == "/tweaks/protocol":
                    owner.protocol_requests.append(self.path)
                    if owner.protocol_error is not None:
                        status, detail = owner.protocol_error
                        self.send_json(status, {"error": detail})
                        return
                    self.send_json(200, {"version": owner.protocol_version}, owner.protocol_content_type)
                    return
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

            def send_json(self, status, payload, content_type="application/json"):
                body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", content_type)
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

                body = json.dumps({"version": 8} if request_line == "GET /tweaks/protocol HTTP/1.1" else owner.payload).encode("utf-8")
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
            snapo.parse_sockets(output, snapo.SOCKET_PREFIX),
            ["snapo_tweaks_7", "snapo_tweaks_93"],
        )
        self.assertEqual(snapo.parse_sockets(output), ["snapo_tweaks_7", "snapo_tweaks_93"])

    def test_adb_tweak_socket_discovery_reads_device_unix_sockets(self):
        recorded = []

        def run(command, **kwargs):
            recorded.append(command)
            output = "1: 0 0 00010000 0001 01 1 @snapo_tweaks_42\n2: 0 0 00010000 0001 01 2 @snapo_network_9\n"
            return type("Result", (), {"returncode": 0, "stdout": output, "stderr": ""})()

        adb = snapo.ADB("/configured/adb", run=run)
        self.assertEqual(adb.sockets("emulator-5554", snapo.SOCKET_PREFIX), ["snapo_tweaks_42"])
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
        options = snapo.parser().parse_args(["apps"])
        self.assertEqual(
            snapo.discover(adb, options),
            [snapo.Server("emulator-5554", "snapo_tweaks_42"), snapo.Server("usb-phone", "snapo_tweaks_8")],
        )

        selected = snapo.parser().parse_args(["apps", "-s", "usb-phone"])
        self.assertEqual(
            snapo.discover(adb, selected, snapo.SOCKET_PREFIX),
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
                command = [*arguments, "-s", "emulator-5554", "--adb", "/configured/adb"]
                if name not in {"set", "action", "reset"}:
                    command.append("--json")
                options = snapo.parser().parse_args(command)
                self.assertEqual(options.command, name)
                self.assertEqual(options.serial, "emulator-5554")
                self.assertEqual(options.adb, "/configured/adb")
                if name not in {"set", "action", "reset"}:
                    self.assertTrue(options.json)

    def test_tweak_commands_preserve_remote_adb_endpoint_validation(self):
        commands = (
            ["apps"],
            ["list"],
            ["get", "Motion/Enabled"],
            ["set", "Motion/Enabled", "false"],
            ["action", "Preview/Refresh"],
            ["reset", "Motion/Enabled"],
            ["watch", "--once"],
        )
        for command in commands:
            with self.subTest(command=command[0]):
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

    def test_main_shows_help_without_starting_adb(self):
        stdout = io.StringIO()
        with mock.patch.object(snapo, "resolve_adb", side_effect=AssertionError("adb should not start")):
            with contextlib.redirect_stdout(stdout):
                result = snapo.main([])

        self.assertEqual(result, 0)
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
            server = snapo.Server("emulator-5554", "snapo_tweaks_42")
            with snapo.TweakConnection(adb, server) as connection:
                response = connection.request("GET", "/tweaks")

        self.assertEqual(response, payload)
        self.assertEqual(
            wire.received,
            [
                "host:transport:emulator-5554",
                "localabstract:snapo_tweaks_42",
                "GET /tweaks/protocol HTTP/1.1",
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
                        result = snapo.main([*arguments])
        return result, stdout.getvalue(), stderr.getvalue(), adb

    def test_apps_identifies_each_running_application_from_its_tweak_server(self):
        with TweakHTTPServer() as wire:
            result, output, errors, adb = self.run_command(["apps", "--json"], wire)

        self.assertEqual(result, 0, errors)
        app = json.loads(output)
        self.assertEqual(app["deviceId"], "emulator-5554")
        self.assertEqual(app["socketName"], "snapo_tweaks_42")
        self.assertEqual(app["processName"], "com.example.tweaks")
        self.assertEqual(app["packageName"], "com.example.tweaks")
        self.assertNotIn("protocolVersion", app)
        self.assertEqual(wire.requests, [])
        self.assertEqual(adb.calls, [])
        self.assertEqual(adb.metadata_calls, [snapo.Server("emulator-5554", "snapo_tweaks_42")] * 2)


    def test_apps_keeps_other_processes_visible_when_metadata_fails(self):
        adb = FakeTweakADB(sockets={"emulator-5554": ["snapo_tweaks_41", "snapo_tweaks_42"]})
        read_process = adb.process_info
        def process_info(server):
            if server.pid == 41:
                raise snapo.SnapOError("process exited")
            return read_process(server)
        adb.process_info = process_info
        with TweakHTTPServer() as wire:
            result, output, errors, _ = self.run_command(["apps", "--json"], wire, adb)
        self.assertEqual(result, 0)
        self.assertIn("process exited", errors)
        rows = [json.loads(line) for line in output.splitlines()]
        self.assertEqual([row["socketName"] for row in rows], ["snapo_tweaks_41", "snapo_tweaks_42"])
        self.assertEqual(rows[1]["processName"], "com.example.tweaks")
        self.assertEqual(wire.requests, [])
        self.assertEqual(adb.calls, [])

    def test_apps_does_not_probe_tool_protocols(self):
        with TweakHTTPServer() as wire:
            result, output, errors, _ = self.run_command(["apps", "--json"], wire)
        self.assertEqual(result, 0, errors)
        self.assertNotIn("protocolVersion", json.loads(output))
        self.assertEqual(wire.protocol_requests, [])

    def test_apps_preserves_existing_human_readable_output(self):
        with TweakHTTPServer() as wire:
            result, output, errors, _ = self.run_command(["apps"], wire)

        self.assertEqual(result, 0, errors)
        self.assertEqual(
            output,
            "emulator-5554:\n    snapo_tweaks_42  com.example.tweaks  pkg:com.example.tweaks\n",
        )


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
        self.assertIn("snapo-tweaks list --all --json", errors)
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
            ("Preview/Text value", "Café ☕", "Café ☕"),
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
                self.assertTrue(errors.startswith("snapo-tweaks:"), errors)
                self.assertEqual(wire.requests, [("GET", "/tweaks", None)])
                self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_set_rejects_actions_without_sending_a_patch(self):
        action = {"name": "Preview/Refresh", "type": "action"}
        with TweakHTTPServer(descriptors=[action]) as wire:
            result, output, errors, adb = self.run_command(["set", action["name"], "true"], wire)

        self.assertEqual(result, 1)
        self.assertEqual(output, "")
        self.assertIn(f"Action '{action['name']}' cannot be set", errors)
        self.assertIn("snapo-tweaks action NAME", errors)
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
        self.assertIn("snapo-tweaks action NAME", errors)
        self.assertEqual(wire.requests, [("GET", "/tweaks", None)])

    def test_reset_requires_exactly_one_target(self):
        for arguments in (["reset"], ["reset", "Motion/Enabled", "--all"]):
            with self.subTest(arguments=arguments):
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    with self.assertRaises(SystemExit) as error:
                        snapo.parser().parse_args([*arguments])
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
                        snapo.parser().parse_args([*arguments])
                self.assertEqual(error.exception.code, 2)
                self.assertIn("set", errors.getvalue())

    def test_action_requires_exactly_one_name(self):
        for arguments in (["action"], ["action", "Preview/Refresh", "unexpected"]):
            with self.subTest(arguments=arguments):
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors):
                    with self.assertRaises(SystemExit) as error:
                        snapo.parser().parse_args([*arguments])
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
                        snapo.parser().parse_args([*command])

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


class ProtocolTests(unittest.TestCase):
    def test_commands_check_tool_protocol_before_data_requests(self):
        for kind, supported, connection_type in (
            ("tweaks", 8, snapo.TweakConnection),
        ):
            for version in (None, True, "4", 0, 1, supported - 1, supported + 1):
                wire = TweakHTTPServer()
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
        with TweakHTTPServer() as wire:
            wire.protocol_error = (404, "Unknown endpoint")
            adb = FakeADB(forward_port=wire.port)
            with self.assertRaisesRegex(snapo.SnapOError, "Cannot check Tweaks Tool protocol.*HTTP 404"):
                with snapo.TweakConnection(adb, snapo.Server("phone", "snapo_tweaks_42")):
                    self.fail("missing endpoint accepted")
        self.assertEqual(wire.requests, [])
        self.assertEqual(adb.calls[-1], ("phone", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_protocol_response_keeps_its_small_size_limit(self):
        with TweakHTTPServer() as wire:
            wire.protocol_version = "x" * 4096
            adb = FakeADB(forward_port=wire.port)
            with self.assertRaisesRegex(snapo.SnapOError, "Cannot check Tweaks Tool protocol.*oversized"):
                with snapo.TweakConnection(adb, snapo.Server("phone", "snapo_tweaks_42")):
                    self.fail("oversized protocol response accepted")
        self.assertEqual(wire.requests, [])
        self.assertEqual(adb.calls[-1], ("phone", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_protocol_requires_json_content_type(self):
        with TweakHTTPServer() as wire:
            wire.protocol_content_type = "text/html"
            adb = FakeADB(forward_port=wire.port)
            with self.assertRaisesRegex(snapo.SnapOError, "Cannot check Tweaks Tool protocol.*JSON response"):
                with snapo.TweakConnection(adb, snapo.Server("phone", "snapo_tweaks_42")):
                    self.fail("non-JSON protocol response accepted")
        self.assertEqual(wire.requests, [])
        self.assertEqual(adb.calls[-1], ("phone", ("forward", "--remove", f"tcp:{wire.port}")))

    def test_tweak_forward_is_removed_when_connection_close_fails(self):
        adb = FakeADB()
        server = snapo.Server("emulator-5554", "snapo_tweaks_42")
        connection = snapo.TweakConnection(adb, server)
        with mock.patch.object(connection, "close", side_effect=RuntimeError("close failed")), mock.patch.object(snapo, "check_protocol"):
            with self.assertRaisesRegex(RuntimeError, "close failed"):
                with connection:
                    pass

        self.assertEqual(adb.calls[-1], ("emulator-5554", ("forward", "--remove", "tcp:27185")))


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
                [str(script), "apps", "--json", "--adb", str(adb)],
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
            self.assertIn("watch", result.stdout)
            self.assertNotIn("intercept", result.stdout)
            for arguments in (["intercept"], ["tweaks", "list"]):
                with self.subTest(arguments=arguments):
                    result = subprocess.run([*command, *arguments], cwd=directory, capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 2)
                    self.assertIn("invalid choice", result.stderr)


if __name__ == "__main__":
    unittest.main()
