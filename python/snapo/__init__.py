"""Write Snap-O network overrides with @route and ordinary async Python functions."""

import base64
import inspect
import json
from collections.abc import MutableMapping
from urllib.parse import urlsplit

MAX_BODY_BYTES = 1024 * 1024
_UNSET = object()


def route(method, path):
    """Match an exact URL path, ignoring its query. Unmatched requests pass through."""
    method = method.upper()
    path = "/" + path.lstrip("/")
    if not method.isascii() or not method.isalpha() or "?" in path or "#" in path:
        raise ValueError("route requires an HTTP method and a path without a query or fragment")

    def decorate(handler):
        if not inspect.iscoroutinefunction(handler):
            raise TypeError("@route handlers must use async def")
        handler.__snapo_routes__ = [*getattr(handler, "__snapo_routes__", []), (method, path)]
        return handler

    return decorate


class Headers(MutableMapping):
    """Case-insensitive headers that preserve repeated values such as Set-Cookie."""

    def __init__(self, entries=()):
        self._entries = [(entry["name"], entry["value"]) for entry in entries]

    def __getitem__(self, name):
        for key, value in reversed(self._entries):
            if key.lower() == name.lower():
                return value
        raise KeyError(name)

    def __setitem__(self, name, value):
        self._entries = [(key, val) for key, val in self._entries if key.lower() != name.lower()]
        self.add(name, value)

    def __delitem__(self, name):
        self[name]
        self._entries = [(key, val) for key, val in self._entries if key.lower() != name.lower()]

    def __iter__(self):
        return iter(dict((key.lower(), key) for key, _ in self._entries).values())

    def __len__(self):
        return len(set(key.lower() for key, _ in self._entries))

    def add(self, name, value):
        if not isinstance(name, str) or not isinstance(value, str) or not name or any(c in name + value for c in "\r\n"):
            raise ValueError("Headers require a name and string value without newlines")
        self._entries.append((name, value))

    def get_all(self, name):
        return [value for key, value in self._entries if key.lower() == name.lower()]

    def _wire(self):
        return [{"name": key, "value": value} for key, value in self._entries]


class Request:
    def __init__(self, wire):
        self.method = wire["method"]
        self.url = wire["url"]
        self.path = urlsplit(self.url).path
        self.headers = Headers(wire.get("headerEntries", []))
        self.body = base64.b64decode(wire.get("body", ""), validate=True)

    @property
    def json(self):
        return json.loads(self.body)


class Response:
    def __init__(self, status=200, body=b"", headers=None):
        self.status = status
        self.headers = headers if headers is not None else Headers()
        self._body = body
        self._json = _UNSET

    @property
    def json(self):
        if self._json is _UNSET:
            self._json = json.loads(self._body)
        return self._json

    @json.setter
    def json(self, value):
        self._json = value

    @property
    def body(self):
        if self._json is not _UNSET:
            return json.dumps(self._json, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
        return self._body

    @body.setter
    def body(self, value):
        self._body = value
        self._json = _UNSET

    @classmethod
    def _from_wire(cls, wire):
        return cls(wire["status"], base64.b64decode(wire["body"], validate=True), Headers(wire["headerEntries"]))

    def _wire(self, method):
        if not isinstance(self.status, int) or not 200 <= self.status <= 599:
            raise ValueError("Response status must be between 200 and 599")
        body = self.body
        if not isinstance(body, bytes):
            raise TypeError("response.body must be bytes; use response.json for JSON")
        if len(body) > MAX_BODY_BYTES:
            raise ValueError("Response body exceeds 1 MiB")
        headers = Headers(self.headers._wire())
        for name in ("Content-Length", "Transfer-Encoding", "Connection", "Keep-Alive", "Trailer"):
            headers.pop(name, None)
        if self._json is not _UNSET:
            headers.pop("Content-Encoding", None)
            headers["Content-Type"] = "application/json; charset=utf-8"
        if self.status in (204, 205, 304):
            body = b""
        elif method != "HEAD":
            headers["Content-Length"] = str(len(body))
        return {
            "status": self.status,
            "headerEntries": headers._wire(),
            "body": base64.b64encode(b"" if method == "HEAD" else body).decode("ascii"),
        }


__all__ = ["route", "Request", "Response", "Headers"]
