"""Check both standalone CLIs against real HTTP response framing."""
import contextlib
import importlib.machinery
import importlib.util
import json
import socket
import sys
from types import SimpleNamespace
import unittest

from test_network import REPOSITORY, snapo

LOADER = importlib.machinery.SourceFileLoader(
    "snapo_tweaks_framing", str(REPOSITORY / "skills/snap-o-tweaks/scripts/snapo-tweaks")
)
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
tweaks = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = tweaks
LOADER.exec_module(tweaks)


class JsonFramingTest(unittest.TestCase):
    def read_response(self, module, wire, limit=1024):
        client, peer = socket.socketpair()
        self.addCleanup(client.close)
        self.addCleanup(peer.close)
        client.settimeout(1)
        peer.sendall(wire)
        peer.shutdown(socket.SHUT_WR)
        transport = SimpleNamespace(socket=client)
        if module is snapo:
            with contextlib.closing(module.HTTPResponse(lambda timeout: transport, "/fixture")) as response:
                return response.read_json(limit)
        connection = module.TweakConnection(None, None)
        connection.connection = SimpleNamespace(open_socket=lambda timeout: transport)
        self.addCleanup(connection.close)
        return connection.request("GET", "/fixture", limit=limit)

    @staticmethod
    def response(body, framing, status=200):
        return (
            f"HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\n"
            f"Connection: close\r\n{framing}\r\n"
        ).encode() + body

    def test_truncated_content_length_is_rejected_even_when_json_is_complete(self):
        body = b'{"value":1}'
        for module in (snapo, tweaks):
            for status in (200, 201):
                with self.subTest(cli=module.__name__, status=status):
                    wire = self.response(body, f"Content-Length: {len(body) + 10}\r\n", status)
                    with self.assertRaises(module.SnapOError):
                        self.read_response(module, wire)

    def test_complete_content_length_is_accepted(self):
        body = '{"value":"café"}'.encode()
        for module in (snapo, tweaks):
            with self.subTest(cli=module.__name__):
                result = self.read_response(module, self.response(body, f"Content-Length: {len(body)}\r\n"))
                self.assertEqual(result, {"value": "café"})

    def test_close_delimited_json_is_accepted(self):
        for module in (snapo, tweaks):
            with self.subTest(cli=module.__name__):
                self.assertEqual(self.read_response(module, self.response(b'{}', "")), {})

    def test_complete_chunked_json_is_accepted(self):
        for module in (snapo, tweaks):
            with self.subTest(cli=module.__name__):
                wire = self.response(b'2\r\n{}\r\n0\r\n\r\n', "Transfer-Encoding: chunked\r\n")
                self.assertEqual(self.read_response(module, wire), {})

    def test_truncated_chunks_are_rejected(self):
        for module in (snapo, tweaks):
            with self.subTest(cli=module.__name__):
                wire = self.response(b'2\r\n{}\r\n', "Transfer-Encoding: chunked\r\n")
                with self.assertRaises(module.SnapOError):
                    self.read_response(module, wire)

    def test_complete_bodies_above_existing_limit_still_fail(self):
        body = json.dumps({"value": "longer than the limit"}).encode()
        for module in (snapo, tweaks):
            with self.subTest(cli=module.__name__):
                wire = self.response(body, f"Content-Length: {len(body)}\r\n")
                with self.assertRaises(module.SnapOError):
                    self.read_response(module, wire, limit=8)


if __name__ == "__main__":
    unittest.main()
