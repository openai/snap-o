import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import type { RequestRecord } from "./cdp";
import { makeCurlCommand } from "./exporters";

const execute = promisify(execFile);
const shells = ["/bin/bash", "/bin/zsh"].filter(existsSync);
const cases = [
  { name: "embedded zero bytes", bytes: Buffer.from([65, 0, 66, 0, 255]), encoding: "base64" },
  { name: "all byte values", bytes: Buffer.from(Array.from({ length: 256 }, (_, index) => index)), encoding: "base64" },
  { name: "binary body starting with at-sign", bytes: Buffer.from("@synthetic-body"), encoding: "base64" },
  { name: "text body starting with at-sign", bytes: Buffer.from("@synthetic-body"), encoding: "utf8" },
  { name: "text containing zero", bytes: Buffer.from("before\0after"), encoding: "utf8" },
  { name: "ordinary text", bytes: Buffer.from("Synthetic text"), encoding: "utf8" },
  { name: "quoted Unicode text", bytes: Buffer.from("café 'quote' $value `literal` \\ end\r\n"), encoding: "utf8" },
  { name: "binary newlines and quotes", bytes: Buffer.from("first\nlast\r\n'\\$"), encoding: "base64" }
];

for (const shell of shells) {
  describe(`copied curl payloads with ${shell}`, () => {
    it.each(cases)("replays $name byte for byte", async ({ bytes, encoding }) => {
      const root = await mkdtemp(join(tmpdir(), "snapo-curl-"));
      let received: Buffer | undefined;
      let method: string | undefined;
      const server = createServer(async (request, response) => {
        const chunks: Uint8Array[] = [];
        for await (const chunk of request) chunks.push(new Uint8Array(chunk));
        received = Buffer.concat(chunks);
        method = request.method;
        response.writeHead(204).end();
      });
      await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
      try {
        const address = server.address();
        if (!address || typeof address === "string") throw new Error("Expected a TCP test address");
        const record: RequestRecord = {
          kind: "request",
          processId: "synthetic-process",
          requestId: "synthetic-request",
          method: "POST",
          url: `http://127.0.0.1:${address.port}/fixture`,
          requestHeaders: [{ name: "Content-Type", value: "application/octet-stream" }],
          responseHeaders: [],
          status: { kind: "success", code: 200 },
          startedAt: 1,
          updatedAt: 2,
          endedAt: 2,
          streamEvents: [],
          streamEventCount: 0,
          requestBodyEncoding: encoding,
          requestBody: encoding === "base64" ? bytes.toString("base64") : bytes.toString("utf8")
        };
        const command = makeCurlCommand(record);
        // Ignore personal curl configuration and proxy settings for this local fixture.
        const wrapper = `curl() { command curl -q --noproxy '*' --max-time 2 --silent --show-error "$@"; };\n`;
        await execute(shell, ["-c", wrapper + command], { cwd: root, timeout: 4000 });
        expect(method).toBe("POST");
        expect(received).toEqual(bytes);
      } finally {
        await new Promise<void>((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
        await rm(root, { recursive: true, force: true });
      }
    });
  });
}
