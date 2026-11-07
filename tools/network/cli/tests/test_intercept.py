import asyncio
import base64
import contextlib
import hashlib
import json
import os
import pathlib
import queue
import threading
import py_compile
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from test_network import snapo

Runner = snapo.Runner
load_routes = snapo.load_routes
Response = snapo.Response

class ResponseTest(unittest.TestCase):
    def test_reading_json_preserves_original_bytes_and_content_headers(self):
        body = b'{ "items": [1, 2], "value": 1.00 }\n'
        wire = {"status": 200, "body": base64.b64encode(body).decode(), "headerEntries": [
            {"name": "Content-Type", "value": "application/problem+json"},
            {"name": "Content-Length", "value": str(len(body))},
            {"name": "ETag", "value": '"original"'},
        ]}
        response = Response._from_wire(wire)
        self.assertEqual([1, 2], response.json["items"])
        self.assertEqual(wire, response._wire("GET"))
        response.json["items"].append(3)
        edited = response._wire("GET")
        self.assertEqual([1, 2, 3], json.loads(base64.b64decode(edited["body"]))["items"])
        response.json["items"].pop()
        self.assertEqual(wire, response._wire("GET"))

    def test_copied_cli_loads_routes_without_a_checkout_or_python_package(self):
        root = pathlib.Path(__file__).resolve().parents[4]
        with tempfile.TemporaryDirectory() as directory:
            script = pathlib.Path(directory) / "snapo-network"
            shutil.copyfile(root / "skills/snap-o-network-inspector/scripts/snapo-network", script)
            script.chmod(0o755)
            routes = pathlib.Path(directory) / "routes.py"
            for module in ("snapo_network", "snapo"):
                routes.write_text(
                    f'from {module} import route, Request, Response, Headers\n'
                    'import snapo_network\n'
                    'assert (route, Request, Response, Headers) == (snapo_network.route, snapo_network.Request, snapo_network.Response, snapo_network.Headers)\n'
                    '@route("GET", "/api/tasks")\nasync def tasks(call):\n    return call.json([])\n'
                )
                for command in ([sys.executable, "-I", str(script)], [str(script)]):
                    with self.subTest(module=module, command=command):
                        result = subprocess.run([*command, "intercept", str(routes), "--check"], cwd=directory, capture_output=True, text=True, timeout=10)
                        self.assertEqual(0, result.returncode, result.stderr)
                        self.assertIn("GET /api/tasks", result.stdout)


class RouteLoaderTest(unittest.IsolatedAsyncioTestCase):
    async def test_reload_ignores_cached_bytecode_for_same_size_and_timestamp(self):
        source = '''from snapo_network import route
version = "old"
@route("GET", "/api/profile")
async def profile(call):
    return version
'''
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "routes.py"
            path.write_text(source)
            stamp = path.stat()
            cache = pathlib.Path(py_compile.compile(
                str(path), doraise=True, invalidation_mode=py_compile.PycInvalidationMode.TIMESTAMP,
            ))
            cached_bytes = cache.read_bytes()
            old_routes, old_digest = load_routes(path)
            updated = source.replace('"old"', '"new"')
            path.write_text(updated)
            os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
            new_routes, new_digest = load_routes(path)

            self.assertEqual("old", await old_routes["GET", "/api/profile"](None))
            self.assertEqual("new", await new_routes["GET", "/api/profile"](None))
            self.assertEqual(hashlib.sha256(source.encode()).digest(), old_digest)
            self.assertEqual(hashlib.sha256(updated.encode()).digest(), new_digest)
            self.assertEqual(cached_bytes, cache.read_bytes())

    async def test_route_file_can_import_sibling_helpers_and_define_dataclasses(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            helper = "snapo_test_route_helper"
            (root / f"{helper}.py").write_text('VERSION = "example"\n')
            self.addCleanup(sys.modules.pop, helper, None)
            path = root / "routes"
            path.write_text('''from __future__ import annotations
from dataclasses import dataclass
from snapo_network import route
from snapo_test_route_helper import VERSION
@dataclass
class State:
    version: str
@route("GET", "/api/profile")
async def profile(call):
    return State(VERSION)
''')
            routes, _ = load_routes(path)
            state = await routes["GET", "/api/profile"](None)
            self.assertEqual("example", state.version)


class InterceptionTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.directory.name) / "prototype.py"
        self.commands = asyncio.Queue()
        self.logs = asyncio.Queue()
        self.events = queue.Queue()
        self.watch_ticks = asyncio.Queue()
        self.runner_task = None
        self.stream = None
        self.loop = asyncio.get_running_loop()
        owner = self

        class FakeResponse:
            def __init__(self, open_socket, path, method="GET", body=None):
                if path == "/interception":
                    owner.assertEqual(method, "POST")
                    command = "routes"
                    self.response = mock.Mock(status=201)
                    self.response.getheader.return_value = "/interception/runner-one"
                    owner.stream = self
                elif path == "/interception/runner-one/routes":
                    owner.assertEqual(method, "PUT")
                    command = "routes"
                else:
                    owner.assertEqual(method, "POST")
                    owner.assertTrue(path.startswith("/interception/runner-one/exchanges/"))
                    body = {**body, "exchangeId": path.split("/")[-1]}
                    command = "decision"
                self.closed = threading.Event()
                owner.loop.call_soon_threadsafe(owner.commands.put_nowait, {"method": command, "params": body})

            def read_json(self):
                return {}

            def read_event(self):
                event = owner.events.get()
                if isinstance(event, Exception):
                    raise event
                return event

            def close(self):
                if not self.closed.is_set():
                    self.closed.set()
                    if self is owner.stream:
                        owner.events.put(snapo.SnapOError("Disconnected"))

        sleep = asyncio.sleep

        async def controlled_sleep(delay, *args, **kwargs):
            if delay == 0.5:
                await self.watch_ticks.get()
            else:
                await sleep(delay, *args, **kwargs)

        for patcher in (
            mock.patch.object(snapo, "HTTPResponse", FakeResponse),
            mock.patch.object(snapo, "NetworkSSE", FakeResponse),
            mock.patch.object(snapo.asyncio, "sleep", controlled_sleep),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    async def asyncTearDown(self):
        if self.runner_task:
            self.runner_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, ConnectionError):
                await self.runner_task
        self.directory.cleanup()

    async def send(self, message, event="message"):
        self.events.put({"event": event, "data": message})

    async def start(self, source, watch=False, timeout=30):
        self.path.write_text(source)
        routes, digest = load_routes(self.path)
        factory = mock.Mock(side_effect=AssertionError("Handler tests must not open sockets"))
        self.runner = Runner(factory, self.path, routes, digest, timeout, watch, self.logs.put_nowait)
        self.runner_task = asyncio.create_task(self.runner.run())
        enable = await self.next_command("routes")
        await self.logs.get()
        return {route["path"]: route["id"] for route in enable["routes"]}

    async def next_command(self, method):
        command = await self.commands.get()
        self.assertEqual(method, command["method"])
        return command["params"]

    async def request(self, identifier, route_id, path="/api/profile", body=None, method="GET"):
        await self.send({"method": "SnapO.intercept.request", "params": {
            "exchangeId": identifier, "routeId": route_id,
            "request": {"method": method, "url": f"https://example.test{path}", "headerEntries": [],
                        "body": base64.b64encode(json.dumps(body).encode()).decode() if body is not None else ""},
        }})

    async def response(self, identifier, body):
        await self.send({"method": "SnapO.intercept.response", "params": {
            "exchangeId": identifier,
            "response": {"status": 200, "headerEntries": [
                {"name": "Content-Length", "value": "2"},
                {"name": "Set-Cookie", "value": "first=1"},
                {"name": "Set-Cookie", "value": "second=2"},
            ], "body": base64.b64encode(json.dumps(body).encode()).decode()},
        }})

    def decoded(self, resolution):
        self.assertEqual("fulfill", resolution["action"])
        return json.loads(base64.b64decode(resolution["response"]["body"]))

    async def test_sixty_four_upstream_calls_do_not_exhaust_http_workers(self):
        routes = await self.start('from snapo_network import route\n@route("GET", "/api/profile")\nasync def profile(call):\n    return await call.upstream()\n')
        for index in range(64):
            await self.request(str(index), routes["/api/profile"])
        pending = [await self.next_command("decision") for _ in range(64)]
        self.assertEqual({str(index) for index in range(64)}, {item["exchangeId"] for item in pending})
        self.assertTrue(all(item["action"] == "upstream" and item["phase"] == "request" for item in pending))
        for index in range(64):
            await self.response(str(index), {"index": index})
        completed = [await self.next_command("decision") for _ in range(64)]
        self.assertEqual(set(range(64)), {self.decoded(item)["index"] for item in completed})
        self.assertTrue(all(item["phase"] == "response" for item in completed))

    async def test_disconnect_cancels_paused_handlers_without_reconnecting(self):
        routes = await self.start('from snapo_network import route\n@route("GET", "/api/profile")\nasync def profile(call):\n    return await call.upstream()\n')
        await self.request("one", routes["/api/profile"])
        await self.next_command("decision")
        self.stream.close()
        with self.assertRaises(snapo.SnapOError):
            await self.runner_task
        self.runner_task = None
        self.assertEqual(self.runner._calls, {})
        self.assertEqual(self.runner._tasks, {})
        self.assertTrue(self.commands.empty())

    async def test_editing_json_sends_upstream_once_and_preserves_repeated_headers(self):
        routes = await self.start('''from snapo_network import route
@route("GET", "api/profile")
async def profile(call):
    assert call.request.path == "/api/profile"
    assert call.request.url.endswith("?source=test")
    response = await call.upstream()
    assert response is await call.upstream()
    response.json["name"] = "Space Captain"
    return response
''')
        await self.request("one", routes["/api/profile"], "/api/profile?source=test")
        upstream = await self.next_command("decision")
        self.assertEqual("upstream", upstream["action"])
        self.assertEqual("request", upstream["phase"])
        await self.response("one", {"name": "Ada", "role": "engineer"})
        result = await self.next_command("decision")
        self.assertEqual("response", result["phase"])
        self.assertEqual({"name": "Space Captain", "role": "engineer"}, self.decoded(result))
        headers = result["response"]["headerEntries"]
        self.assertEqual(["first=1", "second=2"], [entry["value"] for entry in headers if entry["name"] == "Set-Cookie"])
        self.assertIn({"name": "Content-Length", "value": str(len(base64.b64decode(result["response"]["body"])))}, headers)

    async def test_module_state_connects_synthetic_create_and_list_without_upstream(self):
        routes = await self.start('''from snapo_network import route
tasks = []
@route("POST", "api/tasks/create")
async def create(call):
    tasks.append(call.request.json)
    return call.json(tasks[-1], status=201)
@route("GET", "api/tasks")
async def list_tasks(call):
    return call.json({"tasks": tasks})
''')
        await self.request("create", routes["/api/tasks/create"], "/api/tasks/create", {"title": "Walk"}, "POST")
        created = await self.next_command("decision")
        self.assertEqual({"title": "Walk"}, self.decoded(created))
        self.assertEqual(201, created["response"]["status"])
        await self.request("list", routes["/api/tasks"], "/api/tasks")
        listed = await self.next_command("decision")
        self.assertEqual({"tasks": [{"title": "Walk"}]}, self.decoded(listed))

    async def test_reload_keeps_in_flight_and_not_yet_announced_requests_on_old_handlers(self):
        routes = await self.start('''from snapo_network import route
@route("GET", "api/profile")
async def profile(call):
    response = await call.upstream()
    response.json["version"] = "old"
    return response
''')
        await self.request("inflight", routes["/api/profile"])
        await self.next_command("decision")
        self.path.write_text('''from snapo_network import route
@route("GET", "api/profile")
async def profile(call):
    return call.json({"version": "new"})
''')
        new_routes, _ = load_routes(self.path)
        install = asyncio.create_task(self.runner.install(new_routes))
        enabled = await self.next_command("routes")
        await install
        await self.response("inflight", {})
        self.assertEqual({"version": "old"}, self.decoded(await self.next_command("decision")))
        await self.request("late", routes["/api/profile"])
        self.assertEqual("upstream", (await self.next_command("decision"))["action"])
        await self.response("late", {})
        self.assertEqual({"version": "old"}, self.decoded(await self.next_command("decision")))
        await self.request("new", enabled["routes"][0]["id"])
        self.assertEqual({"version": "new"}, self.decoded(await self.next_command("decision")))

    async def test_concurrent_handlers_can_release_one_response_before_another(self):
        routes = await self.start('''from snapo_network import route
import asyncio
ready = asyncio.Event()
@route("GET", "api/profile")
async def profile(call):
    await ready.wait()
    return call.json({"profile": True})
@route("GET", "api/settings")
async def settings(call):
    ready.set()
    return call.json({"settings": True})
''')
        await self.request("profile", routes["/api/profile"])
        await self.request("settings", routes["/api/settings"], "/api/settings")
        results = [await self.next_command("decision") for _ in range(2)]
        self.assertEqual({"profile", "settings"}, {result["exchangeId"] for result in results})
        self.assertTrue(all(result["action"] == "fulfill" for result in results))

    async def test_handler_exception_fails_the_request_without_sending_it_upstream(self):
        routes = await self.start('''from snapo_network import route
@route("GET", "api/profile")
async def profile(call):
    raise ValueError("broken prototype")
''')
        await self.request("failed", routes["/api/profile"])
        result = await self.next_command("decision")
        self.assertEqual("fail", result["action"])
        self.assertIn("ValueError", result["error"])

    async def test_watch_rejects_broken_edits_and_recovers_on_the_next_save(self):
        original = '''from snapo_network import route
@route("GET", "api/profile")
async def profile(call):
    return call.json({"version": "old"})
'''
        routes = await self.start(original, watch=True)
        self.path.write_text("broken syntax!!!")
        self.watch_ticks.put_nowait(None)
        self.assertIn("Reload failed", await self.logs.get())
        await self.request("old", routes["/api/profile"])
        self.assertEqual({"version": "old"}, self.decoded(await self.next_command("decision")))
        self.path.write_text(original.replace('"old"', '"new"'))
        self.watch_ticks.put_nowait(None)
        enabled = await self.next_command("routes")
        await self.request("new", enabled["routes"][0]["id"])
        self.assertEqual({"version": "new"}, self.decoded(await self.next_command("decision")))


if __name__ == "__main__":
    unittest.main()
