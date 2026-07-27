import assert from "node:assert/strict";
import { createServer } from "node:http";
import { after, before, test } from "node:test";

import {
  createTweakPanelServer,
  discoverTweakTarget,
  parseAdbDevices,
  parseAdbForwards,
  parseArguments,
  parseTweakSockets,
} from "./server.mjs";

const app = {
  name: "Snap-O Tweaks Demo",
  packageName: "com.openai.snapo.demo.tweaks",
};

const initialTweaks = [
  {
    name: "Font size",
    type: "int",
    default: 36,
    value: 36,
    min: 16,
    max: 72,
    step: 1,
  },
  {
    name: "Accent color",
    type: "color",
    default: "#5468FF",
    value: "#5468FF",
  },
  {
    name: "Use spring",
    type: "boolean",
    default: true,
    value: true,
  },
];

const icon = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x11, 0x22,
]);

let upstream;
let upstreamUrl;
let panel;

function reply(response, status, body, headers = {}) {
  const bytes = Buffer.isBuffer(body)
    ? body
    : Buffer.from(JSON.stringify(body));

  response.writeHead(status, {
    "Content-Length": bytes.length,
    "Content-Type": Buffer.isBuffer(body)
      ? "image/png"
      : "application/json; charset=utf-8",
    ...headers,
  });
  response.end(bytes);
}

before(async () => {
  upstream = createServer(async (request, response) => {
    if (request.url === "/app" && request.method === "GET") {
      reply(response, 200, app);
      return;
    }

    if (request.url === "/app/icon" && request.method === "GET") {
      reply(response, 200, icon);
      return;
    }

    if (request.url === "/tweaks" && request.method === "GET") {
      reply(response, 200, { tweaks: initialTweaks });
      return;
    }

    if (request.url === "/tweaks" && request.method === "PATCH") {
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));

      if (payload.values?.["Font size"] === 48.5) {
        reply(response, 422, { error: "Font size must be a whole number." });
        return;
      }

      reply(response, 200, {
        tweaks: Object.entries(payload.values).map(([name, value]) => ({
          name,
          value,
        })),
      });
      return;
    }

    reply(response, 405, { error: "Method not allowed." }, { Allow: "GET" });
  });

  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  upstreamUrl = `http://127.0.0.1:${upstream.address().port}`;
  panel = await createTweakPanelServer({ target: upstreamUrl });
});

after(async () => {
  if (panel) await panel.close();
  if (upstream) await new Promise((resolve) => upstream.close(resolve));
});

test("serves the host-side tweaks panel", async () => {
  const response = await fetch(panel.url);
  const html = await response.text();

  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /text\/html/);
  assert.match(html, /Snap-O Tweaks/);
  assert.match(html, /\/app\.js/);
  assert.match(html, /\/styles\.css/);
  assert.match(
    html,
    /class="app-icon-frame">[\s\S]*?class="app-icon"[\s\S]*?id="connection-status"/,
  );
  assert.doesNotMatch(html, /class="masthead"/);
  assert.doesNotMatch(html, /<h1\b/);
});

test("serves the browser application and stylesheet", async () => {
  for (const [pathname, type] of [
    ["/app.js", /text\/javascript/],
    ["/styles.css", /text\/css/],
  ]) {
    const response = await fetch(new URL(pathname, panel.url));
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type"), type);
    assert.ok((await response.text()).length > 0);
  }
});

test("proxies app metadata without adding an icon URL", async () => {
  const response = await fetch(new URL("/app", panel.url));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), app);
});

test("proxies the application icon as an unchanged PNG", async () => {
  const response = await fetch(new URL("/app/icon", panel.url));

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "image/png");
  assert.equal(Number(response.headers.get("content-length")), icon.length);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), icon);
});

test("proxies the original flat tweak descriptors", async () => {
  const response = await fetch(new URL("/tweaks", panel.url));

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { tweaks: initialTweaks });
});

test("forwards live tweak patches", async () => {
  const response = await fetch(new URL("/tweaks", panel.url), {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ values: { "Font size": 48 } }),
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    tweaks: [{ name: "Font size", value: 48 }],
  });
});

test("preserves Android validation errors", async () => {
  const response = await fetch(new URL("/tweaks", panel.url), {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ values: { "Font size": 48.5 } }),
  });

  assert.equal(response.status, 422);
  assert.deepEqual(await response.json(), {
    error: "Font size must be a whole number.",
  });
});

test("preserves allowed methods from the Android app", async () => {
  const response = await fetch(new URL("/app", panel.url), { method: "POST" });

  assert.equal(response.status, 405);
  assert.equal(response.headers.get("allow"), "GET");
});

test("does not expose arbitrary proxy paths", async () => {
  const response = await fetch(new URL("/somewhere-else", panel.url));

  assert.equal(response.status, 404);
  assert.deepEqual(await response.json(), { error: "Not found." });
});

test("rejects non-local Android tweaks targets", async () => {
  await assert.rejects(
    createTweakPanelServer({ target: "https://example.com" }),
    /localhost URL/,
  );
});

test("finds physical-device tweaks forwards before emulators", () => {
  const output = [
    "emulator-5554 tcp:56426 localabstract:snapo_tweaks_25725",
    "51091FDAS002W3 tcp:59318 localabstract:snapo_tweaks_28795",
    "emulator-5554 tcp:61074 localabstract:snapo_tweaks_26103",
    "51091FDAS002W3 tcp:4000 localabstract:snapo_network_28795",
  ].join("\n");

  assert.deepEqual(parseAdbForwards(output), [
    {
      serial: "51091FDAS002W3",
      port: 59318,
      socket: "localabstract:snapo_tweaks_28795",
    },
    {
      serial: "emulator-5554",
      port: 56426,
      socket: "localabstract:snapo_tweaks_25725",
    },
    {
      serial: "emulator-5554",
      port: 61074,
      socket: "localabstract:snapo_tweaks_26103",
    },
  ]);
});

test("prefers the most recently connected physical Android device", () => {
  const output = [
    "List of devices attached",
    "emulator-5554 device product:sdk model:Android_SDK transport_id:1",
    "OLD123 device product:oriole model:Pixel_6 transport_id:4",
    "NEW456 device product:komodo model:Pixel_9_Pro_XL transport_id:8",
    "LOCKED789 unauthorized usb:1-2",
    "OFFLINE321 offline transport_id:12",
  ].join("\n");

  assert.deepEqual(parseAdbDevices(output), [
    { serial: "NEW456", model: "Pixel 9 Pro XL", transportId: 8 },
    { serial: "OLD123", model: "Pixel 6", transportId: 4 },
    { serial: "emulator-5554", model: "Android SDK", transportId: 1 },
  ]);
});

test("discovers only live Snap-O Tweaks app sockets", () => {
  const output = [
    "0000: 0001 01 10 @snapo_network_8800",
    "0000: 0001 01 11 @snapo_tweaks_4312",
    "0000: 0001 01 12 @snapo_tweaks_6976",
    "0000: 0001 01 13 @snapo_tweaks_4312",
    "0000: 0001 01 14 @unrelated_debug_socket",
  ].join("\n");

  assert.deepEqual(parseTweakSockets(output), [
    { name: "snapo_tweaks_6976", pid: 6976 },
    { name: "snapo_tweaks_4312", pid: 4312 },
  ]);
});

test("creates its own ADB forward for a running app", async () => {
  const calls = [];
  const run = async (executable, args) => {
    calls.push([executable, ...args]);

    if (args[0] === "devices") {
      return {
        stdout: [
          "List of devices attached",
          "PIXEL123 device model:Pixel_9_Pro_XL transport_id:9",
        ].join("\n"),
      };
    }

    if (args[0] === "forward") {
      return { stdout: "" };
    }

    if (args.includes("/proc/net/unix")) {
      return { stdout: "0000: 0001 01 10 @snapo_tweaks_6976\n" };
    }

    if (args.includes("tcp:0")) {
      return { stdout: "49231\n" };
    }

    throw new Error(`Unexpected ADB arguments: ${args.join(" ")}`);
  };

  const fetcher = async (url) => {
    assert.equal(url.href, "http://127.0.0.1:49231/app");
    return new Response(JSON.stringify(app), {
      headers: { "Content-Type": "application/json" },
    });
  };

  const target = await discoverTweakTarget({
    adb: "sample-adb",
    run,
    fetcher,
  });

  assert.equal(target.href, "http://127.0.0.1:49231/");
  assert.deepEqual(
    calls.find((call) => call.includes("tcp:0")),
    [
      "sample-adb",
      "-s",
      "PIXEL123",
      "forward",
      "tcp:0",
      "localabstract:snapo_tweaks_6976",
    ],
  );
});

test("reuses an existing live forward", async () => {
  const calls = [];
  const run = async (executable, args) => {
    calls.push([executable, ...args]);

    if (args[0] === "devices") {
      return {
        stdout: "List of devices attached\nPIXEL123 device transport_id:9\n",
      };
    }

    if (args[0] === "forward") {
      return {
        stdout:
          "PIXEL123 tcp:49231 localabstract:snapo_tweaks_6976\n",
      };
    }

    if (args.includes("/proc/net/unix")) {
      return { stdout: "0000: 0001 01 10 @snapo_tweaks_6976\n" };
    }

    throw new Error(`Unexpected ADB arguments: ${args.join(" ")}`);
  };

  const target = await discoverTweakTarget({
    adb: "sample-adb",
    run,
    fetcher: async () => new Response(JSON.stringify(app)),
  });

  assert.equal(target.href, "http://127.0.0.1:49231/");
  assert.equal(calls.some((call) => call.includes("tcp:0")), false);
});

test("honors explicit device and Android package selection", async () => {
  const calls = [];
  const run = async (executable, args) => {
    calls.push([executable, ...args]);

    if (args[0] === "devices") {
      return {
        stdout: [
          "List of devices attached",
          "NEW456 device model:Pixel_9 transport_id:8",
          "CHOSEN123 device model:Pixel_8 transport_id:5",
        ].join("\n"),
      };
    }

    if (args[0] === "forward") {
      return {
        stdout:
          "CHOSEN123 tcp:49231 localabstract:snapo_tweaks_6976\n",
      };
    }

    if (args.includes("/proc/net/unix")) {
      return { stdout: "0000: 0001 01 10 @snapo_tweaks_6976\n" };
    }

    throw new Error(`Unexpected ADB arguments: ${args.join(" ")}`);
  };

  const target = await discoverTweakTarget({
    serial: "CHOSEN123",
    packageName: app.packageName,
    adb: "sample-adb",
    run,
    fetcher: async () => new Response(JSON.stringify(app)),
  });

  assert.equal(target.href, "http://127.0.0.1:49231/");
  assert.equal(
    calls.some((call) => call.includes("NEW456") && call.includes("shell")),
    false,
  );
});

test("recovers automatically when the Android app process changes", async () => {
  const replacementApp = {
    name: "Reconnected Tweaks Demo",
    packageName: app.packageName,
  };

  function makeUpstream(identity) {
    return createServer((request, response) => {
      if (request.url === "/app") {
        reply(response, 200, identity);
      } else if (request.url === "/tweaks") {
        reply(response, 200, { tweaks: initialTweaks });
      } else {
        reply(response, 404, { error: "Not found." });
      }
    });
  }

  const original = makeUpstream(app);
  const replacement = makeUpstream(replacementApp);
  await Promise.all([
    new Promise((resolve) => original.listen(0, "127.0.0.1", resolve)),
    new Promise((resolve) => replacement.listen(0, "127.0.0.1", resolve)),
  ]);

  const originalTarget = new URL(
    `http://127.0.0.1:${original.address().port}`,
  );
  const replacementTarget = new URL(
    `http://127.0.0.1:${replacement.address().port}`,
  );
  let target = originalTarget;
  let discoveries = 0;
  const recoveringPanel = await createTweakPanelServer({
    async discoverTarget() {
      discoveries += 1;
      return target;
    },
  });

  try {
    const first = await fetch(new URL("/app", recoveringPanel.url));
    assert.deepEqual(await first.json(), app);
    assert.equal(discoveries, 1);

    target = replacementTarget;
    original.closeAllConnections();
    await new Promise((resolve) => original.close(resolve));

    const recovered = await fetch(new URL("/app", recoveringPanel.url));
    assert.equal(recovered.status, 200);
    assert.deepEqual(await recovered.json(), replacementApp);
    assert.equal(discoveries, 2);
    assert.equal(recoveringPanel.target.href, replacementTarget.href);

    const tweaks = await fetch(new URL("/tweaks", recoveringPanel.url));
    assert.equal(tweaks.status, 200);
    assert.deepEqual(await tweaks.json(), { tweaks: initialTweaks });
  } finally {
    await recoveringPanel.close();
    replacement.closeAllConnections();
    await new Promise((resolve) => replacement.close(resolve));

    if (original.listening) {
      original.closeAllConnections();
      await new Promise((resolve) => original.close(resolve));
    }
  }
});

test("parses explicit device, package, and port options", () => {
  assert.deepEqual(
    parseArguments([
      "--serial",
      "PIXEL123",
      "--package",
      "com.openai.snapo.demo.tweaks",
      "--port",
      "4176",
    ]),
    {
      port: 4176,
      serial: "PIXEL123",
      packageName: "com.openai.snapo.demo.tweaks",
    },
  );

  assert.throws(() => parseArguments(["--serial"]), /requires an Android device/);
  assert.throws(() => parseArguments(["--package"]), /requires an Android package/);
  assert.throws(() => parseArguments(["--target"]), /requires an HTTP localhost/);
});
