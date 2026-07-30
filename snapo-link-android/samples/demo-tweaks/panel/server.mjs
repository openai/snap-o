import { execFile } from "node:child_process";
import { createServer } from "node:http";
import { homedir } from "node:os";
import path from "node:path";
import { readFile } from "node:fs/promises";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";

const runFile = promisify(execFile);
const directory = path.dirname(fileURLToPath(import.meta.url));
const maximumBodyBytes = 64 * 1024;

const staticFiles = new Map([
  ["/", { name: "index.html", type: "text/html; charset=utf-8" }],
  ["/app.js", { name: "app.js", type: "text/javascript; charset=utf-8" }],
  ["/styles.css", { name: "styles.css", type: "text/css; charset=utf-8" }],
  [
    "/icons/chevron-down.svg",
    { name: "icons/chevron-down.svg", type: "image/svg+xml" },
  ],
]);

const tweakRoutes = new Set(["/app", "/app/icon", "/tweaks", "/tweaks/events"]);

export function parseAdbDevices(output) {
  return output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => /^\S+\s+device(?:\s|$)/.test(line))
    .map((line) => {
      const [serial] = line.split(/\s+/);
      const model = line.match(/\bmodel:(\S+)/)?.[1];
      const transport = line.match(/\btransport_id:(\d+)/)?.[1];

      return {
        serial,
        model: model?.replaceAll("_", " ") ?? serial,
        transportId: Number(transport ?? 0),
      };
    })
    .sort((left, right) => {
      const leftIsEmulator = left.serial.startsWith("emulator-");
      const rightIsEmulator = right.serial.startsWith("emulator-");

      if (leftIsEmulator !== rightIsEmulator) {
        return Number(leftIsEmulator) - Number(rightIsEmulator);
      }

      return right.transportId - left.transportId;
    });
}

export function parseTweakSockets(output) {
  return [...new Set(
    [...output.matchAll(/@snapo_tweaks_(\d+)\b/g)].map((match) => match[1]),
  )]
    .map((identifier) => ({
      name: `snapo_tweaks_${identifier}`,
      pid: Number(identifier),
    }))
    .sort((left, right) => right.pid - left.pid);
}

export function parseAdbForwards(output) {
  return output
    .split(/\r?\n/)
    .map((line) => line.trim().split(/\s+/))
    .filter(
      ([serial, local, remote]) =>
        Boolean(serial) &&
        /^tcp:\d+$/.test(local ?? "") &&
        /^localabstract:snapo_tweaks_\d+$/.test(remote ?? ""),
    )
    .map(([serial, local, remote]) => ({
      serial,
      port: Number(local.slice(4)),
      socket: remote,
    }))
    .sort((left, right) => {
      const leftIsEmulator = left.serial.startsWith("emulator-");
      const rightIsEmulator = right.serial.startsWith("emulator-");
      return Number(leftIsEmulator) - Number(rightIsEmulator);
    });
}

function adbCandidates() {
  const candidates = [];

  for (const root of [process.env.ANDROID_HOME, process.env.ANDROID_SDK_ROOT]) {
    if (root) candidates.push(path.join(root, "platform-tools", "adb"));
  }

  candidates.push(path.join(homedir(), "Library/Android/sdk/platform-tools/adb"));
  candidates.push("adb");
  return [...new Set(candidates)];
}

async function probeTweakTarget(target, packageName, fetcher) {
  try {
    const response = await fetcher(new URL("/app", target), {
      signal: AbortSignal.timeout(1_500),
    });

    if (!response.ok) return null;

    const app = await response.json();
    if (typeof app.name !== "string" || typeof app.packageName !== "string") {
      return null;
    }

    return !packageName || app.packageName === packageName ? app : null;
  } catch {
    return null;
  }
}

function describeTweakApp(app, device, socket, target) {
  return {
    id: `${device.serial}:${app.packageName}`,
    name: app.name,
    packageName: app.packageName,
    deviceName: device.model,
    deviceSerial: device.serial,
    pid: socket?.pid,
    target: validateTarget(target),
  };
}

async function createDeviceForward(adb, serial, socket, run) {
  const { stdout } = await run(
    adb,
    ["-s", serial, "forward", "tcp:0", `localabstract:${socket}`],
    { timeout: 4_000 },
  );
  const port = Number(stdout.trim());

  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("ADB returned an invalid tweak forward.");
  }

  return { port, target: new URL(`http://127.0.0.1:${port}`) };
}

async function discoverOnDevice({
  adb,
  device,
  forwards,
  packageName,
  run,
  fetcher,
}) {
  let sockets = [];

  try {
    const { stdout } = await run(
      adb,
      ["-s", device.serial, "shell", "cat", "/proc/net/unix"],
      { timeout: 4_000 },
    );
    sockets = parseTweakSockets(stdout);
  } catch {
    // Existing ADB forwards can still work when socket inspection is unavailable.
  }

  const deviceForwards = forwards.filter(
    (forward) => forward.serial === device.serial,
  );

  for (const socket of sockets) {
    const existing = deviceForwards.filter(
      (forward) => forward.socket === `localabstract:${socket.name}`,
    );

    for (const forward of existing) {
      const target = new URL(`http://127.0.0.1:${forward.port}`);
      if (await probeTweakTarget(target, packageName, fetcher)) {
        return target;
      }
    }

    let created;

    try {
      created = await createDeviceForward(adb, device.serial, socket.name, run);

      if (await probeTweakTarget(created.target, packageName, fetcher)) {
        return created.target;
      }
    } catch {
      continue;
    }

    try {
      await run(
        adb,
        ["-s", device.serial, "forward", "--remove", `tcp:${created.port}`],
        { timeout: 4_000 },
      );
    } catch {
      // Discovery must not fail because a rejected temporary forward vanished.
    }
  }

  for (const forward of deviceForwards) {
    const target = new URL(`http://127.0.0.1:${forward.port}`);

    if (await probeTweakTarget(target, packageName, fetcher)) {
      return target;
    }
  }

  return null;
}

async function discoverAppsOnDevice({
  adb,
  device,
  forwards,
  packageName,
  run,
  fetcher,
}) {
  let sockets = [];

  try {
    const { stdout } = await run(
      adb,
      ["-s", device.serial, "shell", "cat", "/proc/net/unix"],
      { timeout: 4_000 },
    );
    sockets = parseTweakSockets(stdout);
  } catch {
    // Existing forwards may remain usable if socket inspection is unavailable.
  }

  const deviceForwards = forwards.filter(
    (forward) => forward.serial === device.serial,
  );
  const apps = new Map();
  const checkedPorts = new Set();

  async function checkForward(target, socket) {
    const normalized = validateTarget(target);
    if (checkedPorts.has(normalized.href)) return false;
    checkedPorts.add(normalized.href);

    const app = await probeTweakTarget(normalized, packageName, fetcher);
    if (!app) return false;

    const description = describeTweakApp(app, device, socket, normalized);
    if (!apps.has(description.id)) apps.set(description.id, description);
    return true;
  }

  for (const socket of sockets) {
    const existing = deviceForwards.filter(
      (forward) => forward.socket === `localabstract:${socket.name}`,
    );
    let found = false;

    for (const forward of existing) {
      found = await checkForward(
        new URL(`http://127.0.0.1:${forward.port}`),
        socket,
      );
      if (found) break;
    }

    if (found) continue;

    let created;

    try {
      created = await createDeviceForward(adb, device.serial, socket.name, run);
      if (await checkForward(created.target, socket)) continue;
    } catch {
      if (!created) continue;
    }

    if (created) {
      try {
        await run(
          adb,
          ["-s", device.serial, "forward", "--remove", `tcp:${created.port}`],
          { timeout: 4_000 },
        );
      } catch {
        // A rejected temporary forward may already have disappeared.
      }
    }
  }

  for (const forward of deviceForwards) {
    const match = forward.socket.match(/snapo_tweaks_(\d+)$/);
    const socket = match
      ? { name: `snapo_tweaks_${match[1]}`, pid: Number(match[1]) }
      : undefined;

    await checkForward(new URL(`http://127.0.0.1:${forward.port}`), socket);
  }

  return [...apps.values()];
}

export async function discoverTweakApps({
  serial,
  packageName,
  adb,
  run = runFile,
  fetcher = fetch,
} = {}) {
  for (const executable of adb ? [adb] : adbCandidates()) {
    let devices;
    let forwards;

    try {
      const [deviceResult, forwardResult] = await Promise.all([
        run(executable, ["devices", "-l"], { timeout: 4_000 }),
        run(executable, ["forward", "--list"], { timeout: 4_000 }),
      ]);
      devices = parseAdbDevices(deviceResult.stdout);
      forwards = parseAdbForwards(forwardResult.stdout);
    } catch {
      continue;
    }

    if (serial) devices = devices.filter((device) => device.serial === serial);

    const discovered = await Promise.all(
      devices.map((device) =>
        discoverAppsOnDevice({
          adb: executable,
          device,
          forwards,
          packageName,
          run,
          fetcher,
        }),
      ),
    );

    return discovered.flat();
  }

  return [];
}

export async function discoverTweakTarget({
  serial,
  packageName,
  adb,
  run = runFile,
  fetcher = fetch,
} = {}) {
  for (const executable of adb ? [adb] : adbCandidates()) {
    let devices;
    let forwards;

    try {
      const [deviceResult, forwardResult] = await Promise.all([
        run(executable, ["devices", "-l"], { timeout: 4_000 }),
        run(executable, ["forward", "--list"], { timeout: 4_000 }),
      ]);
      devices = parseAdbDevices(deviceResult.stdout);
      forwards = parseAdbForwards(forwardResult.stdout);
    } catch {
      continue;
    }

    if (serial) {
      devices = devices.filter((device) => device.serial === serial);
    }

    for (const device of devices) {
      const target = await discoverOnDevice({
        adb: executable,
        device,
        forwards,
        packageName,
        run,
        fetcher,
      });

      if (target) return target;
    }
  }

  const selection = [
    serial && `device ${serial}`,
    packageName && `package ${packageName}`,
  ].filter(Boolean);
  const scope = selection.length > 0 ? ` for ${selection.join(" and ")}` : "";

  throw new Error(
    `No running Snap-O Tweaks app found${scope}. ` +
      "Connect an authorized Android device and open a tweaks-enabled app, " +
      "or pass --target http://127.0.0.1:<port>.",
  );
}

function validateTarget(value) {
  const target = value instanceof URL ? value : new URL(value);

  if (
    target.protocol !== "http:" ||
    !["127.0.0.1", "localhost", "[::1]"].includes(target.hostname)
  ) {
    throw new Error("The tweak target must be an HTTP localhost URL.");
  }

  return target;
}

function jsonResponse(response, status, payload, additionalHeaders = {}) {
  const data = Buffer.from(JSON.stringify(payload));
  response.writeHead(status, {
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": data.length,
    "X-Content-Type-Options": "nosniff",
    ...additionalHeaders,
  });
  response.end(data);
}

async function readRequestBody(request) {
  let size = 0;
  const chunks = [];

  for await (const chunk of request) {
    size += chunk.length;

    if (size > maximumBodyBytes) {
      const error = new Error("Request body exceeds 64 KB.");
      error.status = 413;
      throw error;
    }

    chunks.push(chunk);
  }

  return Buffer.concat(chunks);
}

async function serveStatic(request, response, file) {
  if (request.method !== "GET" && request.method !== "HEAD") {
    jsonResponse(response, 405, { error: "Method not allowed." }, {
      Allow: "GET, HEAD",
    });
    return;
  }

  const data = await readFile(path.join(directory, file.name));
  response.writeHead(200, {
    "Cache-Control": "no-store",
    "Content-Type": file.type,
    "Content-Length": data.length,
    "X-Content-Type-Options": "nosniff",
  });
  response.end(request.method === "HEAD" ? undefined : data);
}

async function proxyTweak(request, response, connection, pathname, target) {
  if (pathname === "/tweaks/events" && request.method === "GET") {
    await proxyTweakEvents(request, response, connection, target);
    return;
  }

  const headers = {};
  let body;

  if (request.method === "PATCH") {
    headers["Content-Type"] = request.headers["content-type"] ?? "application/json";
    body = await readRequestBody(request);
  }

  const upstreamPath = pathname + new URL(request.url, "http://127.0.0.1").search;
  const performRequest = () => fetch(new URL(upstreamPath, target ?? connection.target), {
    method: request.method,
    headers,
    body,
    signal: AbortSignal.timeout(8_000),
  });

  let upstream;

  try {
    upstream = await performRequest();
  } catch (error) {
    if (connection.fixed || target) throw error;

    await connection.reconnect();
    upstream = await performRequest();
  }

  const data = Buffer.from(await upstream.arrayBuffer());
  const responseHeaders = {
    "Cache-Control": "no-store",
    "Content-Length": data.length,
    "X-Content-Type-Options": "nosniff",
  };

  for (const name of ["content-type", "allow"]) {
    const value = upstream.headers.get(name);
    if (value) responseHeaders[name] = value;
  }

  response.writeHead(upstream.status, responseHeaders);
  response.end(data);
}

async function proxyTweakEvents(request, response, connection, target) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  response.once("close", abort);

  try {
    const performRequest = () => fetch(
      new URL(request.url, target ?? connection.target),
      {
        method: request.method,
        headers: { Accept: "text/event-stream" },
        signal: controller.signal,
      },
    );

    let upstream;

    try {
      upstream = await performRequest();
    } catch (error) {
      if (connection.fixed || target || controller.signal.aborted) throw error;

      await connection.reconnect();
      upstream = await performRequest();
    }

    if (!upstream.ok || !upstream.body) {
      const data = Buffer.from(await upstream.arrayBuffer());
      response.writeHead(upstream.status, {
        "Cache-Control": "no-store",
        "Content-Type": upstream.headers.get("content-type") ?? "application/json",
        "Content-Length": data.length,
        "X-Content-Type-Options": "nosniff",
      });
      response.end(data);
      return;
    }

    response.writeHead(upstream.status, {
      "Cache-Control": "no-cache",
      "Content-Type": "text/event-stream; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    });

    await pipeline(Readable.fromWeb(upstream.body), response);
  } finally {
    response.removeListener("close", abort);
    controller.abort();
  }
}

function publicApp(app) {
  return {
    id: app.id,
    name: app.name,
    packageName: app.packageName,
    deviceName: app.deviceName,
    deviceSerial: app.deviceSerial,
  };
}

async function handleApps(request, response, connection, pathname) {
  if (pathname === "/apps") {
    if (request.method !== "GET") {
      jsonResponse(response, 405, { error: "Method not allowed." }, {
        Allow: "GET",
      });
      return;
    }

    await connection.refreshApps();
    jsonResponse(response, 200, {
      apps: connection.apps.map(publicApp),
      selectedAppId: connection.selectedAppId ?? null,
    });
    return;
  }

  if (pathname === "/apps/selection") {
    if (request.method !== "PUT") {
      jsonResponse(response, 405, { error: "Method not allowed." }, {
        Allow: "PUT",
      });
      return;
    }

    let payload;

    try {
      payload = JSON.parse((await readRequestBody(request)).toString("utf8"));
    } catch (error) {
      if (error.status === 413) throw error;
      jsonResponse(response, 400, { error: "Expected a JSON app selection." });
      return;
    }

    const selected = connection.apps.find((app) => app.id === payload?.id);

    if (!selected) {
      jsonResponse(response, 404, { error: "The selected app is not available." });
      return;
    }

    connection.selectedAppId = selected.id;
    connection.target = selected.target;
    jsonResponse(response, 200, { app: publicApp(selected) });
    return;
  }

  const iconMatch = pathname.match(/^\/apps\/([^/]+)\/icon$/);

  if (iconMatch) {
    if (request.method !== "GET") {
      jsonResponse(response, 405, { error: "Method not allowed." }, {
        Allow: "GET",
      });
      return;
    }

    let id;

    try {
      id = decodeURIComponent(iconMatch[1]);
    } catch {
      jsonResponse(response, 400, { error: "Invalid app identifier." });
      return;
    }

    const app = connection.apps.find((candidate) => candidate.id === id);

    if (!app) {
      jsonResponse(response, 404, { error: "The selected app is not available." });
      return;
    }

    await proxyTweak(request, response, connection, "/app/icon", app.target);
    return;
  }

  jsonResponse(response, 404, { error: "Not found." });
}

function createHandler(connection) {
  return async (request, response) => {
    try {
      const pathname = new URL(request.url, "http://127.0.0.1").pathname;
      const file = staticFiles.get(pathname);

      if (file) {
        await serveStatic(request, response, file);
        return;
      }

      if (pathname === "/apps" || pathname.startsWith("/apps/")) {
        await handleApps(request, response, connection, pathname);
        return;
      }

      if (tweakRoutes.has(pathname)) {
        if (!connection.target) {
          await connection.refreshApps();
        }

        if (!connection.target) {
          jsonResponse(response, 503, {
            error: "No running Snap-O Tweaks app found.",
          });
          return;
        }

        await proxyTweak(request, response, connection, pathname);
        return;
      }

      jsonResponse(response, 404, { error: "Not found." });
    } catch (error) {
      if (!response.headersSent) {
        const status = error.status === 413 ? 413 : 502;
        const message =
          status === 413
            ? error.message
            : "Cannot reach the Android tweaks endpoint.";
        jsonResponse(response, status, { error: message });
      } else {
        response.destroy(error);
      }
    }
  };
}

export async function createTweakPanelServer({
  target,
  serial,
  packageName,
  discoverTarget = discoverTweakTarget,
  discoverApps = discoverTweakApps,
  hostname = "127.0.0.1",
  port = 0,
} = {}) {
  const configuredTarget = target ?? process.env.SNAPO_TWEAKS_URL;
  const legacyDiscovery =
    !configuredTarget && discoverTarget !== discoverTweakTarget;
  const connection = {
    target: configuredTarget
      ? validateTarget(configuredTarget)
      : legacyDiscovery
        ? validateTarget(await discoverTarget({ serial, packageName }))
        : undefined,
    fixed: Boolean(configuredTarget),
    apps: [],
    selectedAppId: undefined,
    refreshing: undefined,
    reconnecting: undefined,
    async refreshApps() {
      if (!this.refreshing) {
        this.refreshing = Promise.resolve()
          .then(async () => {
            if (this.fixed || legacyDiscovery) {
              const identity = await probeTweakTarget(this.target, packageName, fetch);

              if (!identity) {
                this.apps = [];
                return;
              }

              const device = {
                serial: serial ?? "local",
                model: serial ?? "Local endpoint",
              };
              const app = describeTweakApp(identity, device, undefined, this.target);
              this.apps = [app];
              this.selectedAppId = app.id;
              return;
            }

            this.apps = await discoverApps({ serial, packageName });
            const selected =
              this.apps.find((app) => app.id === this.selectedAppId) ??
              this.apps[0];
            this.selectedAppId = selected?.id;
            this.target = selected ? validateTarget(selected.target) : undefined;
          })
          .finally(() => {
            this.refreshing = undefined;
          });
      }

      return this.refreshing;
    },
    async reconnect() {
      if (!this.reconnecting) {
        this.reconnecting = Promise.resolve()
          .then(async () => {
            if (legacyDiscovery) {
              this.target = validateTarget(
                await discoverTarget({ serial, packageName }),
              );
              return;
            }

            const selectedId = this.selectedAppId;
            await this.refreshApps();

            if (!this.target || (selectedId && this.selectedAppId !== selectedId)) {
              throw new Error("The selected Android tweaks app is not available.");
            }
          })
          .finally(() => {
            this.reconnecting = undefined;
          });
      }

      return this.reconnecting;
    },
  };

  if (!configuredTarget && !legacyDiscovery) await connection.refreshApps();
  const server = createServer(createHandler(connection));

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, hostname, () => {
      server.removeListener("error", reject);
      resolve();
    });
  });

  const address = server.address();

  return {
    server,
    get target() {
      return connection.target;
    },
    url: `http://${hostname}:${address.port}`,
    close() {
      return new Promise((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    },
  };
}

export function parseArguments(args) {
  const options = { port: 4175 };

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];

    if (argument === "--target") {
      options.target = args[++index];
    } else if (argument.startsWith("--target=")) {
      options.target = argument.slice("--target=".length);
    } else if (argument === "--serial") {
      options.serial = args[++index];
    } else if (argument.startsWith("--serial=")) {
      options.serial = argument.slice("--serial=".length);
    } else if (argument === "--package") {
      options.packageName = args[++index];
    } else if (argument.startsWith("--package=")) {
      options.packageName = argument.slice("--package=".length);
    } else if (argument === "--port") {
      options.port = Number(args[++index]);
    } else if (argument.startsWith("--port=")) {
      options.port = Number(argument.slice("--port=".length));
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }

  if (!Number.isInteger(options.port) || options.port < 0 || options.port > 65_535) {
    throw new Error("The port must be a whole number from 0 to 65535.");
  }

  if (Object.hasOwn(options, "serial") && !options.serial) {
    throw new Error("The --serial option requires an Android device serial.");
  }

  if (Object.hasOwn(options, "packageName") && !options.packageName) {
    throw new Error("The --package option requires an Android package name.");
  }

  if (Object.hasOwn(options, "target") && !options.target) {
    throw new Error("The --target option requires an HTTP localhost URL.");
  }

  return options;
}

async function main() {
  const panel = await createTweakPanelServer(parseArguments(process.argv.slice(2)));
  console.log(`Snap-O Tweaks panel: ${panel.url}`);
  console.log(
    panel.target
      ? `Android tweaks endpoint: ${panel.target}`
      : "Waiting for a running Snap-O Tweaks app.",
  );

  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.once(signal, async () => {
      await panel.close();
      process.exit(0);
    });
  }
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
