import asyncio
import base64
import contextlib
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_snapo import snapo

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
        root = pathlib.Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            script = pathlib.Path(directory) / "snapo"
            shutil.copyfile(root / "scripts/snapo", script)
            routes = pathlib.Path(directory) / "routes.py"
            routes.write_text('from snapo import route\n@route("GET", "/api/tasks")\nasync def tasks(call):\n    return call.json([])\n')
            result = subprocess.run([sys.executable, "-I", str(script), "network", "intercept", str(routes), "--check"], cwd=directory, capture_output=True, text=True, timeout=10)
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertIn("GET /api/tasks", result.stdout)


class InterceptionTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.directory.name) / "prototype.py"
        self.commands = asyncio.Queue()
        self.logs = asyncio.Queue()
        self.connected = asyncio.get_running_loop().create_future()
        self.server = await asyncio.start_server(self.accept, "127.0.0.1", 0)
        self.peer_task = None
        self.writer = None
        self.runner_task = None

    async def asyncTearDown(self):
        if self.runner_task:
            self.runner_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, ConnectionError):
                await self.runner_task
        if self.writer:
            self.writer.close()
            await self.writer.wait_closed()
        if self.peer_task:
            await self.peer_task
        self.server.close()
        await self.server.wait_closed()
        self.directory.cleanup()

    async def accept(self, reader, writer):
        self.peer_task = asyncio.current_task()
        self.writer = writer
        self.assertEqual(b"HelloSnapO\n", await reader.readline())
        self.connected.set_result(True)
        while line := await reader.readline():
            command = json.loads(line)
            await self.commands.put(command)
            await self.send({"id": command["id"], "result": {}})

    async def send(self, message):
        self.writer.write(json.dumps(message).encode() + b"\n")
        await self.writer.drain()

    async def start(self, source, watch=False, timeout=30):
        self.path.write_text(source)
        routes, digest = load_routes(self.path)
        reader, writer = await asyncio.open_connection("127.0.0.1", self.server.sockets[0].getsockname()[1])
        self.runner = Runner(reader, writer, self.path, routes, digest, timeout, watch, self.logs.put_nowait)
        self.runner_task = asyncio.create_task(self.runner.run())
        await self.connected
        enable = await self.next_command("SnapO.intercept.enable")
        await asyncio.wait_for(self.logs.get(), 2)
        return {route["path"]: route["id"] for route in enable["routes"]}

    async def next_command(self, method):
        command = await asyncio.wait_for(self.commands.get(), 2)
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

    async def test_editing_json_sends_upstream_once_and_preserves_repeated_headers(self):
        routes = await self.start('''from snapo import route
@route("GET", "api/profile")
async def profile(call):
    response = await call.upstream()
    assert response is await call.upstream()
    response.json["name"] = "Space Captain"
    return response
''')
        await self.request("one", routes["/api/profile"])
        upstream = await self.next_command("SnapO.intercept.resolve")
        self.assertEqual("upstream", upstream["action"])
        await self.response("one", {"name": "Ada", "role": "engineer"})
        result = await self.next_command("SnapO.intercept.resolve")
        self.assertEqual({"name": "Space Captain", "role": "engineer"}, self.decoded(result))
        headers = result["response"]["headerEntries"]
        self.assertEqual(["first=1", "second=2"], [entry["value"] for entry in headers if entry["name"] == "Set-Cookie"])
        self.assertIn({"name": "Content-Length", "value": str(len(base64.b64decode(result["response"]["body"])))}, headers)

    async def test_module_state_connects_synthetic_create_and_list_without_upstream(self):
        routes = await self.start('''from snapo import route
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
        created = await self.next_command("SnapO.intercept.resolve")
        self.assertEqual({"title": "Walk"}, self.decoded(created))
        self.assertEqual(201, created["response"]["status"])
        await self.request("list", routes["/api/tasks"], "/api/tasks")
        listed = await self.next_command("SnapO.intercept.resolve")
        self.assertEqual({"tasks": [{"title": "Walk"}]}, self.decoded(listed))

    async def test_reload_keeps_in_flight_and_not_yet_announced_requests_on_old_handlers(self):
        routes = await self.start('''from snapo import route
@route("GET", "api/profile")
async def profile(call):
    response = await call.upstream()
    response.json["version"] = "old"
    return response
''')
        await self.request("inflight", routes["/api/profile"])
        await self.next_command("SnapO.intercept.resolve")
        self.path.write_text('''from snapo import route
@route("GET", "api/profile")
async def profile(call):
    return call.json({"version": "new"})
''')
        new_routes, _ = load_routes(self.path)
        install = asyncio.create_task(self.runner.install(new_routes))
        enabled = await self.next_command("SnapO.intercept.enable")
        await install
        await self.response("inflight", {})
        self.assertEqual({"version": "old"}, self.decoded(await self.next_command("SnapO.intercept.resolve")))
        await self.request("late", routes["/api/profile"])
        self.assertEqual("upstream", (await self.next_command("SnapO.intercept.resolve"))["action"])
        await self.response("late", {})
        self.assertEqual({"version": "old"}, self.decoded(await self.next_command("SnapO.intercept.resolve")))
        await self.request("new", enabled["routes"][0]["id"])
        self.assertEqual({"version": "new"}, self.decoded(await self.next_command("SnapO.intercept.resolve")))

    async def test_concurrent_handlers_can_release_one_response_before_another(self):
        routes = await self.start('''from snapo import route
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
        results = [await self.next_command("SnapO.intercept.resolve") for _ in range(2)]
        self.assertEqual({"profile", "settings"}, {result["exchangeId"] for result in results})
        self.assertTrue(all(result["action"] == "fulfill" for result in results))

    async def test_handler_exception_fails_the_request_without_sending_it_upstream(self):
        routes = await self.start('''from snapo import route
@route("GET", "api/profile")
async def profile(call):
    raise ValueError("broken prototype")
''')
        await self.request("failed", routes["/api/profile"])
        result = await self.next_command("SnapO.intercept.resolve")
        self.assertEqual("fail", result["action"])
        self.assertIn("ValueError", result["error"])

    async def test_watch_rejects_broken_edits_and_recovers_on_the_next_save(self):
        original = '''from snapo import route
@route("GET", "api/profile")
async def profile(call):
    return call.json({"version": "old"})
'''
        routes = await self.start(original, watch=True)
        self.path.write_text("broken syntax!!!")
        self.assertIn("Reload failed", await asyncio.wait_for(self.logs.get(), 2))
        await self.request("old", routes["/api/profile"])
        self.assertEqual({"version": "old"}, self.decoded(await self.next_command("SnapO.intercept.resolve")))
        self.path.write_text(original.replace('"old"', '"new"'))
        enabled = await self.next_command("SnapO.intercept.enable")
        await self.request("new", enabled["routes"][0]["id"])
        self.assertEqual({"version": "new"}, self.decoded(await self.next_command("SnapO.intercept.resolve")))


if __name__ == "__main__":
    unittest.main()
