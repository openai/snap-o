import contextlib
import gzip
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import socket
import tempfile
import threading
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "scripts" / "snapo"
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
        self.thread = threading.Thread(target=self.run, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, error_type, error, traceback):
        self.thread.join(timeout=3)
        self.listener.close()
        if self.failure:
            raise self.failure
        if self.thread.is_alive():
            raise AssertionError("wire server did not stop")

    def run(self):
        try:
            connection, _ = self.listener.accept()
            with connection:
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


class ADBTests(unittest.TestCase):
    def test_parser_leaves_default_adb_endpoint_to_configured_adb(self):
        options = snapo.parser().parse_args(["network", "list"])
        self.assertIsNone(options.adb_host)
        self.assertIsNone(options.adb_port)

    def test_default_endpoint_does_not_override_namespace_shim(self):
        recorded = []

        def run(command, **kwargs):
            recorded.append(command)
            return type("Result", (), {"returncode": 0, "stdout": "", "stderr": ""})()

        adb = snapo.ADB("/configured/namespace-adb", run=run)
        self.assertFalse(adb.has_explicit_endpoint)
        self.assertEqual(adb.endpoint, ("127.0.0.1", 5037))
        adb.command("devices", "-l", serial="emulator-5554")
        self.assertEqual(
            recorded,
            [["/configured/namespace-adb", "-s", "emulator-5554", "devices", "-l"]],
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

        adb = snapo.ADB("/configured/adb", host="namespace.test", port=15037, run=run)
        self.assertTrue(adb.has_explicit_endpoint)
        adb.command("devices", "-l", serial="emulator-5554")
        self.assertEqual(
            recorded,
            [["/configured/adb", "-H", "namespace.test", "-P", "15037", "-s", "emulator-5554", "devices", "-l"]],
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
        fixture = SCRIPT.parents[1] / "contracts" / "network" / "v1" / "http-replay.jsonl"
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


class OutputTests(unittest.TestCase):
    def test_sanitizes_all_sensitive_event_headers(self):
        request = snapo.sanitize_event(request_event())
        response = snapo.sanitize_event(response_event())
        self.assertEqual(request["params"]["request"]["headers"]["Authorization"], snapo.REDACTED)
        self.assertEqual(request["params"]["request"]["headers"]["Cookie"], snapo.REDACTED)
        self.assertEqual(response["params"]["response"]["headers"]["Set-Cookie"], snapo.REDACTED)

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

    def test_decodes_gzip_body_with_standard_library(self):
        encoded = snapo.base64.b64encode(gzip.compress(b'{"ok":true}')).decode("ascii")
        self.assertEqual(snapo.decoded_body(encoded, "base64", "gzip"), '{"ok":true}')

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


if __name__ == "__main__":
    unittest.main()
