import { randomUUID } from "node:crypto";
import type { WebContents } from "electron";
import type { Duplex } from "node:stream";
import { AdbClient, type Device } from "./adb.js";
import { SnapOLinkConnection, type AppIconRecord, type HelloRecord, type SnapORecord } from "./snapo-link.js";
import type {
  CdpMessage,
  LoadBodiesInput,
  RequestBodies,
  SnapOServer,
  StartStreamInput,
  StreamEvent,
  StreamStarted,
  StreamStatus
} from "../src/network/bridge-types.js";

interface ServerState {
  key: string;
  deviceId: string;
  socketName: string;
  connection: SnapOLinkConnection;
  deviceDisplayTitle: string;
  hello: HelloRecord | null;
  appIcon: AppIconRecord | null;
  packageNameHint: string | null;
  features: string[];
  schemaVersion: number | null;
  isConnected: boolean;
}

interface StreamSubscription {
  streamId: string;
  serverKey: string;
  webContents: WebContents;
}

interface PendingCommand {
  resolve: (message: CdpMessage) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
}

export class NetworkInspectorBackend {
  private readonly adb = new AdbClient();
  private readonly servers = new Map<string, ServerState>();
  private readonly devices = new Map<string, Device>();
  private readonly streams = new Map<string, StreamSubscription>();
  private readonly pendingCommands = new Map<string, PendingCommand>();
  private readonly inFlightBodyCommands = new Map<string, Promise<CdpMessage>>();
  private pollTimer: NodeJS.Timeout | null = null;
  private refreshInFlight: Promise<void> | null = null;
  private nextCommandId = 1;

  async listServers(): Promise<SnapOServer[]> {
    this.ensureStarted();
    await this.refresh();
    return this.currentServers();
  }

  async startStream(input: StartStreamInput, webContents: WebContents): Promise<StreamStarted> {
    this.ensureStarted();
    await this.refresh();

    const serverKey = toServerKey(input);
    const state = this.servers.get(serverKey);
    if (state == null || !state.isConnected) {
      throw new Error(`Snap-O server is not connected: ${input.deviceId}/${input.socketName}`);
    }

    const streamId = randomUUID();
    const subscription: StreamSubscription = { streamId, serverKey, webContents };
    this.streams.set(streamId, subscription);
    webContents.once("destroyed", () => {
      this.streams.delete(streamId);
    });

    state.connection.sendFeatureOpened("network");
    this.sendStatus(webContents, {
      streamId,
      state: "started",
      message: `Connected to ${state.deviceId}/${state.socketName}`
    });
    return { streamId };
  }

  async stopStream(streamId: string): Promise<void> {
    this.streams.delete(streamId);
  }

  async loadBodies(input: LoadBodiesInput): Promise<RequestBodies> {
    const serverKey = toServerKey(input);
    const includeRequestBody = input.includeRequestBody !== false;
    const includeResponseBody = input.includeResponseBody !== false;
    const [requestBody, responseBody] = await Promise.allSettled([
      includeRequestBody
        ? this.sendNetworkBodyCommand(serverKey, input.requestId, "request", "Network.getRequestPostData")
        : Promise.resolve(null),
      includeResponseBody
        ? this.sendNetworkBodyCommand(serverKey, input.requestId, "response", "Network.getResponseBody")
        : Promise.resolve(null)
    ]);

    const requestResult = fulfilledResult(requestBody);
    const responseResult = fulfilledResult(responseBody);
    return {
      requestId: input.requestId,
      requestBody: stringField(requestResult?.result, "postData"),
      responseBody: stringField(responseResult?.result, "body"),
      responseBodyBase64Encoded: booleanField(responseResult?.result, "base64Encoded")
    };
  }

  shutdown(): void {
    if (this.pollTimer != null) {
      clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
    for (const streamId of this.streams.keys()) {
      this.streams.delete(streamId);
    }
    for (const [key, state] of this.servers) {
      this.removeServer(key, state);
    }
    for (const command of this.pendingCommands.values()) {
      clearTimeout(command.timeout);
      command.reject(new Error("Network inspector backend shut down"));
    }
    this.pendingCommands.clear();
    this.inFlightBodyCommands.clear();
  }

  private ensureStarted(): void {
    if (this.pollTimer != null) return;
    this.pollTimer = setInterval(() => {
      void this.refresh();
    }, SocketPollIntervalMs);
    void this.refresh();
  }

  private async refresh(): Promise<void> {
    if (this.refreshInFlight != null) return this.refreshInFlight;
    this.refreshInFlight = this.refreshNow().finally(() => {
      this.refreshInFlight = null;
    });
    return this.refreshInFlight;
  }

  private async refreshNow(): Promise<void> {
    let devices: Device[];
    try {
      devices = await this.adb.devicesList();
    } catch {
      this.removeAllServers();
      this.devices.clear();
      return;
    }

    this.devices.clear();
    for (const device of devices) {
      this.devices.set(device.id, device);
    }

    const seenServerKeys = new Set<string>();
    await Promise.all(
      devices.map(async (device) => {
        let sockets: Set<string>;
        try {
          sockets = parseSnapOSockets(await this.adb.listUnixSockets(device.id));
        } catch {
          sockets = new Set();
        }

        for (const socketName of sockets) {
          const key = toServerKey({ deviceId: device.id, socketName });
          seenServerKeys.add(key);
          if (!this.servers.has(key)) {
            await this.connectServer(device, socketName);
          } else {
            const state = this.servers.get(key);
            if (state != null) {
              state.deviceDisplayTitle = device.displayTitle;
            }
          }
        }
      })
    );

    for (const [key, state] of Array.from(this.servers)) {
      if (!seenServerKeys.has(key)) {
        this.removeServer(key, state);
      }
    }
  }

  private async connectServer(device: Device, socketName: string): Promise<void> {
    const key = toServerKey({ deviceId: device.id, socketName });
    let stream: Duplex;
    try {
      stream = await this.adb.openLocalAbstract(device.id, socketName);
    } catch {
      return;
    }

    const connection = new SnapOLinkConnection(
      stream,
      (record) => this.handleRecord(key, record),
      () => {
        const state = this.servers.get(key);
        if (state != null) this.removeServer(key, state);
      }
    );

    const state: ServerState = {
      key,
      deviceId: device.id,
      socketName,
      connection,
      deviceDisplayTitle: device.displayTitle,
      hello: null,
      appIcon: null,
      packageNameHint: null,
      features: [],
      schemaVersion: null,
      isConnected: true
    };
    this.servers.set(key, state);
    connection.start();
    void this.populatePackageNameHint(state);
  }

  private removeAllServers(): void {
    for (const [key, state] of Array.from(this.servers)) {
      this.removeServer(key, state);
    }
  }

  private removeServer(key: string, state: ServerState): void {
    this.servers.delete(key);
    state.isConnected = false;
    state.connection.stop();

    for (const [streamId, subscription] of Array.from(this.streams)) {
      if (subscription.serverKey === key) {
        this.sendStatus(subscription.webContents, {
          streamId,
          state: "exit",
          message: `Disconnected from ${state.deviceId}/${state.socketName}`
        });
        this.streams.delete(streamId);
      }
    }

    for (const [commandKey, command] of Array.from(this.pendingCommands)) {
      if (commandKey.startsWith(`${key}:`)) {
        clearTimeout(command.timeout);
        command.reject(new Error(`Disconnected from ${state.deviceId}/${state.socketName}`));
        this.pendingCommands.delete(commandKey);
      }
    }
  }

  private async populatePackageNameHint(state: ServerState): Promise<void> {
    const pid = pidFromSocketName(state.socketName);
    if (pid == null) return;

    try {
      const output = await this.adb.runShellString(state.deviceId, `cat /proc/${pid}/cmdline 2>/dev/null`);
      const candidate =
        output
          .split("\u0000")
          .find((part) => part.trim().length > 0)
          ?.trim() ??
        output
          .split(/\r?\n/)
          .find((part) => part.trim().length > 0)
          ?.trim() ??
        null;
      if (candidate != null && candidate.length > 0 && this.servers.get(state.key) === state) {
        state.packageNameHint = candidate;
      }
    } catch {
      // Package name hints are nice-to-have; Hello will provide canonical metadata once connected.
    }
  }

  private handleRecord(serverKey: string, record: SnapORecord): void {
    const state = this.servers.get(serverKey);
    if (state == null) return;

    if (record.kind === "hello") {
      state.hello = record.value;
      state.schemaVersion = record.value.schemaVersion ?? null;
      state.features = record.value.features?.map((feature) => feature.id) ?? [];
      return;
    }

    if (record.kind === "appIcon") {
      if (state.hello?.packageName != null && state.hello.packageName !== record.value.packageName) return;
      state.appIcon = record.value;
      return;
    }

    if (record.kind === "network") {
      this.handleNetworkMessage(serverKey, record.value);
    }
  }

  private handleNetworkMessage(serverKey: string, message: CdpMessage): void {
    if (message.id != null && message.method == null) {
      const commandKey = commandMapKey(serverKey, message.id);
      const pending = this.pendingCommands.get(commandKey);
      if (pending != null) {
        clearTimeout(pending.timeout);
        this.pendingCommands.delete(commandKey);
        pending.resolve(message);
        return;
      }
    }

    const state = this.servers.get(serverKey);
    if (state == null) return;
    for (const subscription of this.streams.values()) {
      if (subscription.serverKey !== serverKey) continue;
      if (subscription.webContents.isDestroyed()) continue;
      const event: StreamEvent = {
        streamId: subscription.streamId,
        server: {
          deviceId: state.deviceId,
          socketName: state.socketName
        },
        message
      };
      subscription.webContents.send("network:event", event);
    }
  }

  private sendNetworkCommand(serverKey: string, method: string, params: Record<string, unknown>): Promise<CdpMessage> {
    const state = this.servers.get(serverKey);
    if (state == null || !state.isConnected) {
      return Promise.reject(new Error(`Snap-O server is not connected: ${serverKey}`));
    }

    const commandId = this.nextCommandId++;
    const message: CdpMessage = {
      id: commandId,
      method,
      params
    };
    const key = commandMapKey(serverKey, commandId);

    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingCommands.delete(key);
        reject(new Error(`Timed out waiting for ${method}`));
      }, BodyCommandTimeoutMs);

      this.pendingCommands.set(key, { resolve, reject, timeout });
      state.connection.sendFeatureCommand("network", message);
    });
  }

  private sendNetworkBodyCommand(
    serverKey: string,
    requestId: string,
    kind: "request" | "response",
    method: string
  ): Promise<CdpMessage> {
    const key = bodyCommandMapKey(serverKey, requestId, kind);
    const existing = this.inFlightBodyCommands.get(key);
    if (existing != null) return existing;

    const command = this.sendNetworkCommand(serverKey, method, { requestId }).finally(() => {
      this.inFlightBodyCommands.delete(key);
    });
    this.inFlightBodyCommands.set(key, command);
    return command;
  }

  private currentServers(): SnapOServer[] {
    return Array.from(this.servers.values())
      .map((state) => {
        const packageName = state.hello?.packageName ?? state.packageNameHint;
        return {
          server: `${state.deviceId}:${state.socketName}`,
          deviceId: state.deviceId,
          socketName: state.socketName,
          deviceDisplayTitle: state.deviceDisplayTitle,
          displayName: packageName ?? state.socketName,
          isConnected: state.isConnected,
          hasHello: state.hello != null,
          pid: state.hello?.pid ?? pidFromSocketName(state.socketName),
          schemaVersion: state.schemaVersion,
          isSchemaNewerThanSupported: state.schemaVersion != null && state.schemaVersion > SupportedSchemaVersion,
          isSchemaOlderThanSupported:
            state.hello != null && (state.schemaVersion == null || state.schemaVersion < SupportedSchemaVersion),
          features: state.features,
          appIconBase64: state.appIcon?.base64Data ?? null,
          packageName,
          appName: packageName
        };
      })
      .sort((a, b) => {
        const device = a.deviceId.localeCompare(b.deviceId);
        return device !== 0 ? device : a.socketName.localeCompare(b.socketName);
      });
  }

  private sendStatus(webContents: WebContents, status: StreamStatus): void {
    if (webContents.isDestroyed()) return;
    webContents.send("network:status", status);
  }
}

function parseSnapOSockets(output: string): Set<string> {
  const result = new Set<string>();
  for (const rawLine of output.split(/\r?\n/)) {
    const token = rawLine.trim().split(/\s+/).filter(Boolean).at(-1);
    if (token != null && token.startsWith("@snapo_server_")) {
      result.add(token.slice(1));
    }
  }
  return result;
}

function toServerKey(input: { deviceId: string; socketName: string }): string {
  return `${input.deviceId}\u0000${input.socketName}`;
}

function commandMapKey(serverKey: string, commandId: number): string {
  return `${serverKey}:${commandId}`;
}

function bodyCommandMapKey(serverKey: string, requestId: string, kind: "request" | "response"): string {
  return `${serverKey}:${kind}:${requestId}`;
}

function pidFromSocketName(socketName: string): number | null {
  const prefix = "snapo_server_";
  if (!socketName.startsWith(prefix)) return null;
  const suffix = socketName.slice(prefix.length);
  return /^\d+$/.test(suffix) ? Number.parseInt(suffix, 10) : null;
}

function fulfilledResult<T>(result: PromiseSettledResult<T>): T | null {
  return result.status === "fulfilled" ? result.value : null;
}

function stringField(record: Record<string, unknown> | undefined, field: string): string | null {
  const value = record?.[field];
  return typeof value === "string" ? value : null;
}

function booleanField(record: Record<string, unknown> | undefined, field: string): boolean | null {
  const value = record?.[field];
  return typeof value === "boolean" ? value : null;
}

const SocketPollIntervalMs = 2_000;
const BodyCommandTimeoutMs = 1_500;
const SupportedSchemaVersion = 3;
