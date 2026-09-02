"""Connection and file lifecycle for Python route handlers. Uses only the standard library."""

import asyncio
import hashlib
import itertools
import pathlib
import sys
import types
import uuid

from . import Headers, Request, Response


def load_routes(path):
    path = pathlib.Path(path).resolve()
    source = path.read_bytes()
    module = types.ModuleType(f"snapo_routes_{uuid.uuid4().hex}")
    module.__file__ = str(path)
    sys.modules[module.__name__] = module
    # Resolve helpers next to the user's file, as Python does for an ordinary script.
    sys.path.insert(0, str(path.parent))
    try:
        exec(compile(source, str(path), "exec"), module.__dict__)
        routes = {}
        seen = set()
        for handler in module.__dict__.values():
            if id(handler) in seen:
                continue
            seen.add(id(handler))
            for key in getattr(handler, "__snapo_routes__", []):
                if key in routes:
                    raise ValueError(f"Duplicate route: {key[0]} {key[1]}")
                routes[key] = handler
        if not routes:
            raise ValueError("No @route handlers found")
        if len(routes) > 128:
            raise ValueError("Register at most 128 routes")
        return routes, hashlib.sha256(source).digest()
    finally:
        sys.path.pop(0)
        sys.modules.pop(module.__name__, None)


class Call:
    def __init__(self, runner, event):
        self.request = Request(event["request"])
        self._runner = runner
        self._id = event["exchangeId"]
        self._upstream_task = None
        self._response = asyncio.get_running_loop().create_future()
        self._finalizing = False

    async def upstream(self):
        """Send the original request on Android once, and return its response."""
        if self._upstream_task is None:
            self._upstream_task = asyncio.create_task(self._fetch())
        return await asyncio.shield(self._upstream_task)

    async def _fetch(self):
        await self._runner.resolve(self._id, "upstream")
        return await self._response

    def json(self, value, status=200, headers=None):
        response = Response(status)
        response.json = value
        if headers:
            response.headers.update(headers)
        return response

    def _cancel(self):
        self._response.cancel()
        if self._upstream_task is not None:
            self._upstream_task.cancel()


class Runner:
    def __init__(self, reader, writer, path, routes, digest, timeout=30, watch=True, log=print):
        self.reader = reader
        self.writer = writer
        self.path = pathlib.Path(path)
        self.routes = routes
        self.digest = digest
        self.timeout = timeout
        self.watch = watch
        self.log = log
        self._ids = itertools.count(1)
        self._commands = {}
        self._handlers = {}
        self._handler_expiry = {}
        self._calls = {}
        self._tasks = {}
        self._reader_task = None

    async def command(self, method, params):
        import json

        identifier = next(self._ids)
        future = asyncio.get_running_loop().create_future()
        self._commands[identifier] = future
        try:
            self.writer.write(json.dumps({"id": identifier, "method": method, "params": params}, separators=(",", ":")).encode() + b"\n")
            await self.writer.drain()
            reply = await asyncio.wait_for(future, 10)
            if "error" in reply:
                raise RuntimeError(reply["error"].get("message", "Snap-O command failed"))
            return reply.get("result", {})
        finally:
            self._commands.pop(identifier, None)

    async def resolve(self, identifier, action, **values):
        await self.command("SnapO.intercept.resolve", {"exchangeId": identifier, "action": action, **values})

    async def install(self, routes):
        generation = uuid.uuid4().hex
        wire = []
        for index, ((method, path), handler) in enumerate(routes.items()):
            identifier = f"{generation}:{index}"
            self._handlers[identifier] = handler
            wire.append({"id": identifier, "method": method, "path": path})
        await self.command("SnapO.intercept.enable", {"routes": wire, "timeoutMs": int(self.timeout * 1000)})
        # Android may have matched an old route but still be reading its request body.
        # Keep retired generations for the lifetime of those paused exchanges.
        now = asyncio.get_running_loop().time()
        active = {item["id"] for item in wire}
        for identifier in list(self._handlers):
            if identifier not in active:
                expiry = self._handler_expiry.setdefault(identifier, now + self.timeout + 1)
                if expiry < now:
                    self._handlers.pop(identifier, None)
                    self._handler_expiry.pop(identifier, None)
        self.routes = routes
        self.log(f"Loaded {len(routes)} route(s) from {self.path}")

    async def run(self):
        self.writer.write(b"HelloSnapO\n")
        await self.writer.drain()
        self._reader_task = asyncio.create_task(self._read())
        watcher = None
        try:
            await self.install(self.routes)
            if self.watch:
                watcher = asyncio.create_task(self._watch())
            running = [self._reader_task, *([watcher] if watcher else [])]
            done, _ = await asyncio.wait(running, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        finally:
            if watcher is not None:
                watcher.cancel()
            self._reader_task.cancel()
            for task in list(self._tasks.values()):
                task.cancel()
            for call in list(self._calls.values()):
                call._cancel()
            for future in list(self._commands.values()):
                if not future.done():
                    future.cancel()
            await asyncio.gather(self._reader_task, *self._tasks.values(), *([watcher] if watcher else []), return_exceptions=True)
            self.writer.close()
            await self.writer.wait_closed()

    async def _read(self):
        import json

        try:
            while True:
                line = await self.reader.readline()
                if not line:
                    raise ConnectionError("Snap-O disconnected; interception stopped")
                message = json.loads(line)
                identifier = message.get("id")
                if identifier in self._commands:
                    future = self._commands[identifier]
                    if not future.done():
                        future.set_result(message)
                    continue
                event = message.get("params", {})
                method = message.get("method")
                if method == "SnapO.intercept.request":
                    identifier = event["exchangeId"]
                    handler = self._handlers.get(event["routeId"])
                    self._tasks[identifier] = asyncio.create_task(self._handle(event, handler))
                elif method == "SnapO.intercept.response":
                    call = self._calls.get(event["exchangeId"])
                    if call is not None and not call._response.done():
                        call._response.set_result(Response._from_wire(event["response"]))
                elif method == "SnapO.intercept.finished":
                    identifier = event["exchangeId"]
                    call = self._calls.get(identifier)
                    if identifier in self._tasks and (call is None or not call._finalizing):
                        if call is not None:
                            self.log(f"Request ended before handler completed: {call.request.method} {call.request.path}")
                        self._tasks[identifier].cancel()
                        if call is None:
                            self._tasks.pop(identifier, None)
        except Exception as error:
            for future in list(self._commands.values()):
                if not future.done():
                    future.set_exception(error)
            raise

    async def _handle(self, event, handler):
        identifier = event["exchangeId"]
        call = Call(self, event)
        self._calls[identifier] = call
        try:
            if handler is None:
                raise RuntimeError("Handler is no longer loaded")
            response = await asyncio.wait_for(handler(call), self.timeout)
            if not isinstance(response, Response):
                raise TypeError("Return call.json(...) or the response from await call.upstream()")
            wire = response._wire(call.request.method)
            call._finalizing = True
            await self.resolve(identifier, "fulfill", response=wire)
            self.log(f"{call.request.method} {call.request.path} -> {response.status}")
        except Exception as error:
            self.log(f"Handler failed for {call.request.method} {call.request.path}: {type(error).__name__}: {error}")
            call._finalizing = True
            try:
                await self.resolve(identifier, "fail", error=f"Python handler failed: {type(error).__name__}")
            except (ConnectionError, RuntimeError, asyncio.TimeoutError):
                pass
        finally:
            call._cancel()
            self._calls.pop(identifier, None)
            self._tasks.pop(identifier, None)

    async def _watch(self):
        last_attempt = self.digest
        while True:
            await asyncio.sleep(0.5)
            try:
                digest = hashlib.sha256(self.path.read_bytes()).digest()
                if digest == last_attempt:
                    continue
                last_attempt = digest
                routes, digest = load_routes(self.path)
            except Exception as error:
                self.log(f"Reload failed; keeping existing routes: {error}")
                continue
            # If registration fails, close the connection. A timed-out acknowledgment
            # cannot tell us whether Android installed the new routes.
            await self.install(routes)
            self.digest = digest


async def run_socket(sock, path, routes, digest, timeout, watch):
    sock.setblocking(False)
    reader, writer = await asyncio.open_connection(sock=sock, limit=2 * 1024 * 1024)
    runner = Runner(reader, writer, path, routes, digest, timeout, watch, log=lambda line: print(line, file=sys.stderr, flush=True))
    await runner.run()
