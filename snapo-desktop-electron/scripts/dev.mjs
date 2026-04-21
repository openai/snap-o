import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import http from "node:http";
import net from "node:net";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const host = "127.0.0.1";
const preferredPort = Number.parseInt(process.env.SNAPO_ELECTRON_DEV_PORT ?? "5173", 10);
const rendererPort = await findAvailablePort(Number.isFinite(preferredPort) ? preferredPort : 5173);
const rendererUrl = `http://${host}:${rendererPort}`;
const electronMain = path.resolve("dist-electron/electron/main.js");
const children = new Set();
let shuttingDown = false;
let electronProcess = null;

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => shutdown(0));
}

console.log(`[dev] Renderer URL: ${rendererUrl}`);

try {
  start("vite", ["--host", host, "--port", String(rendererPort), "--strictPort"]);
  start("tsc", ["-p", "tsconfig.electron.json", "--watch", "--preserveWatchOutput"]);

  await Promise.all([waitForHttp(rendererUrl), waitForFile(electronMain)]);

  electronProcess = start("electron", ["."], {
    env: {
      ...process.env,
      SNAPO_ELECTRON_DEV_SERVER_URL: rendererUrl
    }
  });

  electronProcess.on("exit", (code, signal) => {
    shutdown(code ?? (signal == null ? 0 : 1));
  });
} catch (error) {
  console.error("[dev]", error);
  shutdown(1);
}

function start(command, args, options = {}) {
  const child = spawn(command, args, {
    stdio: "inherit",
    shell: process.platform === "win32",
    ...options
  });
  children.add(child);
  child.on("exit", (code) => {
    children.delete(child);
    if (!shuttingDown && child !== electronProcess && code !== 0) {
      shutdown(code ?? 1);
    }
  });
  child.on("error", (error) => {
    console.error(`[dev] Failed to start ${command}:`, error);
    shutdown(1);
  });
  return child;
}

function shutdown(code) {
  if (shuttingDown) return;
  shuttingDown = true;
  for (const child of children) {
    child.kill("SIGTERM");
  }
  process.exitCode = code;
}

async function findAvailablePort(startPort) {
  for (let port = startPort; port < startPort + 100; port += 1) {
    if (await isPortAvailable(port)) return port;
  }
  throw new Error(`No available port found from ${startPort} to ${startPort + 99}`);
}

function isPortAvailable(port) {
  return new Promise((resolve) => {
    const server = net.createServer();
    server.once("error", () => resolve(false));
    server.once("listening", () => {
      server.close(() => resolve(true));
    });
    server.listen(port, host);
  });
}

async function waitForHttp(url) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (await canReach(url)) return;
    await delay(100);
  }
  throw new Error(`Timed out waiting for ${url}`);
}

function canReach(url) {
  return new Promise((resolve) => {
    const request = http.get(url, (response) => {
      response.resume();
      resolve(response.statusCode != null && response.statusCode < 500);
    });
    request.once("error", () => resolve(false));
    request.setTimeout(1_000, () => {
      request.destroy();
      resolve(false);
    });
  });
}

async function waitForFile(filePath) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (existsSync(filePath)) return;
    await delay(100);
  }
  throw new Error(`Timed out waiting for ${filePath}`);
}
