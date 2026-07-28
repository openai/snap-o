import assert from "node:assert/strict";
import { createServer } from "node:http";
import { after, before, test } from "node:test";

import {
  createTweakPanelServer,
  discoverTweakApps,
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

    if (request.url === "/tweaks/events" && request.method === "GET") {
      response.writeHead(200, {
        "Cache-Control": "no-cache",
        "Content-Type": "text/event-stream; charset=utf-8",
      });
      response.write(`event: tweaks\ndata: ${JSON.stringify({ tweaks: initialTweaks })}\n\n`);
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
    /class="server-app-icon">[\s\S]*?class="app-icon"[\s\S]*?id="connection-status"/,
  );
  assert.doesNotMatch(html, /class="masthead"/);
  assert.doesNotMatch(html, /<aside\b/);
  assert.doesNotMatch(html, /class="sidebar"/);
  assert.doesNotMatch(html, /class="sidebar-heading"/);
  assert.doesNotMatch(html, /class="app-header"/);
  assert.doesNotMatch(html, /id="app-count"/);
  assert.match(html, /class="inspector-toolbar"/);
  assert.match(html, /id="app-picker"/);
  assert.match(html, /id="app-chevron"/);
  assert.match(html, /id="app-list"/);
  assert.match(html, /id="inspector-segments"/);
  assert.match(html, /id="tweak-sections"/);
  assert.match(html, /id="reset-button"/);
  assert.match(html, /href="#mock-icon-rotate-ccw"/);
  assert.match(html, /id="reset-button"[\s\S]*?id="app-picker"/);
  assert.match(html, /id="app-picker"[\s\S]*?id="inspector-segments"/);
  assert.doesNotMatch(html, /id="refresh-button"/);
});

test("serves the browser application and stylesheet", async () => {
  for (const [pathname, type] of [
    ["/app.js", /text\/javascript/],
    ["/styles.css", /text\/css/],
    ["/icons/chevron-down.svg", /image\/svg\+xml/],
  ]) {
    const response = await fetch(new URL(pathname, panel.url));
    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type"), type);
    assert.ok((await response.text()).length > 0);
  }
});

test("anchors the app and actions to the Mac-style full-width toolbar", async () => {
  const response = await fetch(new URL("/styles.css", panel.url));
  const styles = await response.text();
  const toolbar = styles.match(/\.toolbar-content\s*\{([^}]*)\}/)?.[1];
  const picker = styles.match(/\.server-select\s*\{([^}]*)\}/)?.[1];
  const content = styles.match(/\.detail-content\s*\{([^}]*)\}/)?.[1];

  assert.ok(toolbar);
  assert.match(toolbar, /width:\s*100%/);
  assert.match(toolbar, /justify-content:\s*flex-start/);
  assert.match(toolbar, /gap:\s*8px/);
  assert.match(toolbar, /padding:\s*8px\s+12px/);
  assert.doesNotMatch(toolbar, /margin-inline:\s*auto/);

  assert.ok(picker);
  assert.match(picker, /width:\s*min\(100%,\s*244px\)/);
  assert.match(picker, /flex:\s*0\s+1\s+244px/);

  assert.ok(content);
  assert.match(content, /width:\s*min\(100%,\s*var\(--content-width\)\)/);
  assert.match(content, /margin-inline:\s*auto/);
});

test("keeps tweak values beside their labels without visible slider bounds", async () => {
  const response = await fetch(new URL("/styles.css", panel.url));
  const styles = await response.text();
  const content = styles.match(/\.tweak-content\s*\{([^}]*)\}/)?.[1];
  const actions = styles.match(/\.tweak-actions\s*\{([^}]*)\}/)?.[1];

  assert.ok(content);
  assert.match(content, /display:\s*flex/);
  assert.match(content, /gap:\s*10px/);
  assert.ok(actions);
  assert.match(actions, /margin-left:\s*auto/);
  assert.doesNotMatch(styles, /\.range-labels\b/);
});

test("shows an icon reset only for changed tweaks", async () => {
  const response = await fetch(new URL("/styles.css", panel.url));
  const styles = await response.text();
  const reset = styles.match(/\.tweak-reset\s*\{\s*display:\s*inline-flex;([^}]*)\}/)?.[0];
  const hidden = styles.match(/\.tweak-reset\[hidden\]\s*\{([^}]*)\}/)?.[1];
  const icon = styles.match(/\.tweak-reset-icon\s*\{([^}]*)\}/)?.[1];
  assert.ok(reset);
  assert.match(reset, /display:\s*inline-flex/);
  assert.ok(hidden);
  assert.match(hidden, /display:\s*none/);
  assert.ok(icon);
  assert.match(icon, /width:\s*13px/);
  assert.doesNotMatch(styles, /\.tweak-row\[data-changed="true"\]\s+\.tweak-label/);
});

test("uses a responsive, monochrome inspector dashboard", async () => {
  const response = await fetch(new URL("/styles.css", panel.url));
  const styles = await response.text();
  const sections = styles.match(/\.tweak-sections\s*\{([^}]*)\}/)?.[1];
  const column = styles.match(/\.tweak-column\s*\{([^}]*)\}/)?.[1];
  const section = styles.match(/\.tweak-section\s*\{([^}]*)\}/)?.[1];
  const ungrouped = styles.match(
    /\.tweak-section\[data-section=""\]\s+\.tweak-list\s*\{([^}]*)\}/,
  )?.[1];
  const slider = styles.match(/\.range-input\s*\{([^}]*)\}/)?.[1];
  const checkbox = styles.match(/\.boolean-input\s*\{([^}]*)\}/)?.[1];

  assert.match(styles, /--control-accent:\s*var\(--text\)/);
  assert.doesNotMatch(styles, /--accent:\s*#[\da-f]+/i);
  assert.ok(sections);
  assert.match(sections, /grid-template-columns:\s*repeat\(auto-fit/);
  assert.ok(column);
  assert.match(column, /display:\s*grid/);
  assert.match(column, /align-content:\s*start/);
  assert.ok(section);
  assert.doesNotMatch(section, /border-top/);
  assert.ok(ungrouped);
  assert.match(ungrouped, /grid-template-columns:\s*repeat\(auto-fit/);
  assert.ok(slider);
  assert.match(slider, /accent-color:\s*var\(--control-accent\)/);
  assert.ok(checkbox);
  assert.match(checkbox, /accent-color:\s*var\(--control-accent\)/);
});

test("serves Network Inspector's official Lucide app-picker chevron", async () => {
  const response = await fetch(new URL("/icons/chevron-down.svg", panel.url));

  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type"), /image\/svg\+xml/);
  assert.match(await response.text(), /<path d="m6 9 6 6 6-6"\s*\/>/);
});

test("proxies app metadata without adding an icon URL", async () => {
  const response = await fetch(new URL("/app", panel.url));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), app);
});

test("lists a fixed-target app without exposing its local upstream", async () => {
  const response = await fetch(new URL("/apps", panel.url));

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    apps: [
      {
        id: `local:${app.packageName}`,
        name: app.name,
        packageName: app.packageName,
        deviceName: "Local endpoint",
        deviceSerial: "local",
      },
    ],
    selectedAppId: `local:${app.packageName}`,
  });
});

test("serves an app-list icon as an unchanged PNG", async () => {
  await fetch(new URL("/apps", panel.url));

  const pathname = `/apps/${encodeURIComponent(`local:${app.packageName}`)}/icon`;
  const response = await fetch(new URL(pathname, panel.url));

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "image/png");
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), icon);
});

test("starts without an Android app and exposes an honest empty state", async () => {
  const emptyPanel = await createTweakPanelServer({
    discoverApps: async () => [],
  });

  try {
    const apps = await fetch(new URL("/apps", emptyPanel.url));
    assert.equal(apps.status, 200);
    assert.deepEqual(await apps.json(), { apps: [], selectedAppId: null });

    const tweaks = await fetch(new URL("/tweaks", emptyPanel.url));
    assert.equal(tweaks.status, 503);
    assert.deepEqual(await tweaks.json(), {
      error: "No running Snap-O Tweaks app found.",
    });
  } finally {
    await emptyPanel.close();
  }
});

test("switches only to a discovered app and routes its tweaks and icon", async () => {
  const first = {
    ...app,
    name: "First Tweaks App",
    packageName: "com.example.first",
  };
  const second = {
    ...app,
    name: "Second Tweaks App",
    packageName: "com.example.second",
  };
  const secondIcon = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x33, 0x44]);
  const patches = [];

  function makeAppServer(identity, image) {
    return createServer(async (request, response) => {
      if (request.url === "/app" && request.method === "GET") {
        reply(response, 200, identity);
      } else if (request.url === "/app/icon" && request.method === "GET") {
        reply(response, 200, image);
      } else if (request.url === "/tweaks" && request.method === "GET") {
        reply(response, 200, { tweaks: initialTweaks });
      } else if (request.url === "/tweaks" && request.method === "PATCH") {
        const chunks = [];
        for await (const chunk of request) chunks.push(chunk);
        const payload = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        patches.push({ packageName: identity.packageName, values: payload.values });
        reply(response, 200, {
          tweaks: Object.entries(payload.values).map(([name, value]) => ({
            name,
            value,
          })),
        });
      } else {
        reply(response, 404, { error: "Not found." });
      }
    });
  }

  const firstServer = makeAppServer(first, icon);
  const secondServer = makeAppServer(second, secondIcon);
  await Promise.all([
    new Promise((resolve) => firstServer.listen(0, "127.0.0.1", resolve)),
    new Promise((resolve) => secondServer.listen(0, "127.0.0.1", resolve)),
  ]);

  const discovered = [
    {
      id: `PIXEL123:${first.packageName}`,
      ...first,
      deviceName: "Pixel 9 Pro XL",
      deviceSerial: "PIXEL123",
      target: new URL(`http://127.0.0.1:${firstServer.address().port}`),
    },
    {
      id: `PIXEL123:${second.packageName}`,
      ...second,
      deviceName: "Pixel 9 Pro XL",
      deviceSerial: "PIXEL123",
      target: new URL(`http://127.0.0.1:${secondServer.address().port}`),
    },
  ];
  const multiPanel = await createTweakPanelServer({
    discoverApps: async () => discovered,
  });

  try {
    const apps = await fetch(new URL("/apps", multiPanel.url));
    const listing = await apps.json();
    assert.equal(listing.apps.length, 2);
    assert.equal(listing.selectedAppId, discovered[0].id);
    assert.equal(Object.hasOwn(listing.apps[0], "target"), false);

    const selection = await fetch(new URL("/apps/selection", multiPanel.url), {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: discovered[1].id }),
    });
    assert.equal(selection.status, 200);
    assert.equal((await selection.json()).app.name, second.name);

    const metadata = await fetch(new URL("/app", multiPanel.url));
    assert.deepEqual(await metadata.json(), second);

    const image = await fetch(
      new URL(`/apps/${encodeURIComponent(discovered[1].id)}/icon`, multiPanel.url),
    );
    assert.deepEqual(Buffer.from(await image.arrayBuffer()), secondIcon);

    const patch = await fetch(new URL("/tweaks", multiPanel.url), {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ values: { "Font size": 44 } }),
    });
    assert.equal(patch.status, 200);
    assert.deepEqual(patches, [
      { packageName: second.packageName, values: { "Font size": 44 } },
    ]);

    const unknown = await fetch(new URL("/apps/selection", multiPanel.url), {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id: "PIXEL123:com.example.unknown" }),
    });
    assert.equal(unknown.status, 404);

    const current = await fetch(new URL("/app", multiPanel.url));
    assert.deepEqual(await current.json(), second);
  } finally {
    await multiPanel.close();
    firstServer.closeAllConnections();
    secondServer.closeAllConnections();
    await Promise.all([
      new Promise((resolve) => firstServer.close(resolve)),
      new Promise((resolve) => secondServer.close(resolve)),
    ]);
  }
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

test("streams complete tweak snapshots while allowing concurrent patches", async () => {
  const controller = new AbortController();

  try {
    const response = await fetch(new URL("/tweaks/events", panel.url), {
      signal: controller.signal,
    });

    assert.equal(response.status, 200);
    assert.match(response.headers.get("content-type"), /text\/event-stream/);

    const reader = response.body.getReader();
    const first = await reader.read();
    const event = new TextDecoder().decode(first.value);

    assert.match(event, /^event: tweaks\ndata: /);
    assert.deepEqual(
      JSON.parse(event.match(/^event: tweaks\ndata: (.+)\n\n$/s)[1]),
      { tweaks: initialTweaks },
    );

    const patch = await fetch(new URL("/tweaks", panel.url), {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ values: { "Font size": 48 } }),
    });

    assert.equal(patch.status, 200);
    assert.deepEqual(await patch.json(), {
      tweaks: [{ name: "Font size", value: 48 }],
    });
  } finally {
    controller.abort();
  }
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

test("discovers every running tweaks app across connected Android devices", async () => {
  const identities = new Map([
    [49231, { name: "Design Preview", packageName: "com.example.design" }],
    [49232, { name: "Motion Study", packageName: "com.example.motion" }],
    [49233, { name: "Tablet Preview", packageName: "com.example.tablet" }],
  ]);
  const run = async (_executable, args) => {
    if (args[0] === "devices") {
      return {
        stdout: [
          "List of devices attached",
          "PHONE123 device model:Pixel_9_Pro_XL transport_id:9",
          "TABLET456 device model:Pixel_Tablet transport_id:5",
        ].join("\n"),
      };
    }

    if (args[0] === "forward") {
      return {
        stdout: [
          "PHONE123 tcp:49231 localabstract:snapo_tweaks_7001",
          "PHONE123 tcp:49232 localabstract:snapo_tweaks_7002",
          "TABLET456 tcp:49233 localabstract:snapo_tweaks_8101",
        ].join("\n"),
      };
    }

    if (args.includes("/proc/net/unix")) {
      return {
        stdout: args.includes("PHONE123")
          ? "@snapo_tweaks_7002\n@snapo_tweaks_7001\n"
          : "@snapo_tweaks_8101\n",
      };
    }

    throw new Error(`Unexpected ADB arguments: ${args.join(" ")}`);
  };
  const apps = await discoverTweakApps({
    adb: "sample-adb",
    run,
    fetcher: async (url) => {
      const identity = identities.get(Number(url.port));
      return identity
        ? new Response(JSON.stringify(identity))
        : new Response(null, { status: 404 });
    },
  });

  assert.deepEqual(
    apps.map(({ id, name, deviceName, pid }) => ({ id, name, deviceName, pid })),
    [
      {
        id: "PHONE123:com.example.motion",
        name: "Motion Study",
        deviceName: "Pixel 9 Pro XL",
        pid: 7002,
      },
      {
        id: "PHONE123:com.example.design",
        name: "Design Preview",
        deviceName: "Pixel 9 Pro XL",
        pid: 7001,
      },
      {
        id: "TABLET456:com.example.tablet",
        name: "Tablet Preview",
        deviceName: "Pixel Tablet",
        pid: 8101,
      },
    ],
  );
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
