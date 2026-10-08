import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { createServer } from "node:http";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import { makeCurlCommand } from "./exporters";

const execute = promisify(execFile);
const shells = ["/bin/bash", "/bin/zsh"].filter(existsSync);
const cases = [
  { method: "HEAD", status: 200, length: 128 },
  { method: "HEAD", status: 404, length: 128 },
  { method: "HEAD", status: 200, length: 0 },
  { method: "GET", status: 200, length: 7 }
];

for (const shell of shells) {
  describe(`HTTP method replay with ${shell}`, () => {
    it.each(cases)("replays $method status $status and length $length", async ({ method, status, length }) => {
      let receivedMethod;
      const server = createServer((request, response) => {
        receivedMethod = request.method;
        response.writeHead(status, {
          "Content-Length": String(length),
          Connection: "close",
          "Content-Type": "text/plain"
        });
        response.end(method === "HEAD" ? undefined : "payload");
      });
      await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
      try {
        const address = server.address();
        const command = makeCurlCommand({
          kind: "request",
          processId: "synthetic-process",
          requestId: "synthetic-request",
          method,
          url: `http://127.0.0.1:${address.port}/fixture`,
          requestHeaders: [],
          responseHeaders: [],
          status: { kind: "success", code: status },
          startedAt: 1,
          updatedAt: 2,
          endedAt: 2,
          streamEvents: [],
          streamEventCount: 0
        });
        // Keep the local fixture independent of personal curl configuration and proxies.
        const wrapper = `curl() { command curl -q --noproxy '*' --max-time 2 --silent --show-error "$@"; };\n`;
        const { stdout } = await execute(shell, ["-c", wrapper + command], { timeout: 4000 });
        expect(receivedMethod).toBe(method);
        if (method === "HEAD") {
          expect(stdout).toContain(`HTTP/1.1 ${status}`);
          expect(stdout.toLowerCase()).toContain(`content-length: ${length}`);
        } else {
          expect(stdout).toBe("payload");
        }
      } finally {
        await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
      }
    });
  });
}

it("preserves custom HEAD requests that include a body", () => {
  const command = makeCurlCommand({
    method: "HEAD",
    url: "http://127.0.0.1/fixture",
    requestHeaders: [],
    requestBody: "synthetic-body"
  });
  expect(command).toContain("--request 'HEAD'");
  expect(command).toContain("--data-binary 'synthetic-body'");
  expect(command).not.toContain("--head");
});
