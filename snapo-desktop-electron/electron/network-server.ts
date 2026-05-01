import type { Duplex } from "node:stream";
import type { CdpMessage } from "../src/network/bridge-types.js";

export interface SnapOAppIcon {
  width: number;
  height: number;
  format?: string;
  base64Data: string;
}

export interface SnapOAppInfoParams {
  protocolVersion: number;
  packageName: string;
  processName: string;
  pid: number;
  serverStartWallMs: number;
  serverStartMonoNs: number;
  mode: string;
  icon?: SnapOAppIcon | null;
}

export type NetworkServerRecord =
  | { kind: "appInfo"; value: SnapOAppInfoParams }
  | { kind: "replayComplete" }
  | { kind: "network"; value: CdpMessage }
  | { kind: "unknown"; method: string; rawJson: string };

export class NetworkServerConnection {
  private lineBuffer = "";
  private skippingOversizedLine = false;
  private stopped = false;

  constructor(
    private readonly stream: Duplex,
    private readonly onRecord: (record: NetworkServerRecord) => void,
    private readonly onClose: (error: Error | null) => void
  ) {}

  start(): void {
    this.stream.on("data", (chunk: Buffer) => {
      this.consume(chunk.toString("utf8"));
    });
    this.stream.on("error", (error: Error) => {
      if (!this.stopped) this.onClose(error);
    });
    this.stream.on("close", () => {
      if (!this.stopped) this.onClose(null);
    });
  }

  stop(): void {
    this.stopped = true;
    this.stream.destroy();
  }

  sendCommand(message: CdpMessage): void {
    if (this.stream.destroyed) return;
    this.stream.write(`${JSON.stringify(message)}\n`, "utf8");
  }

  private consume(text: string): void {
    for (const char of text) {
      if (char === "\n") {
        if (!this.skippingOversizedLine) this.dispatchLine(this.lineBuffer);
        this.lineBuffer = "";
        this.skippingOversizedLine = false;
      } else if (char !== "\r") {
        if (this.skippingOversizedLine) continue;
        if (this.lineBuffer.length >= MaxNdjsonLineChars) {
          this.lineBuffer = "";
          this.skippingOversizedLine = true;
        } else {
          this.lineBuffer += char;
        }
      }
    }
  }

  private dispatchLine(line: string): void {
    if (line.trim().length === 0) return;
    this.onRecord(decodeNetworkServerLine(line));
  }
}

function decodeNetworkServerLine(line: string): NetworkServerRecord {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch {
    return { kind: "unknown", method: "<unparseable>", rawJson: line };
  }

  if (!isRecord(value)) {
    return { kind: "unknown", method: "<non-object>", rawJson: line };
  }

  const method = typeof value.method === "string" ? value.method : "<missing-method>";
  if (method === "SnapO.appInfo" && isAppInfoParams(value.params)) {
    return { kind: "appInfo", value: value.params };
  }
  if (method === "SnapO.replayComplete") {
    return { kind: "replayComplete" };
  }
  if (isCdpMessage(value)) {
    return { kind: "network", value };
  }

  return { kind: "unknown", method, rawJson: line };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

function isAppInfoParams(value: unknown): value is SnapOAppInfoParams {
  if (!isRecord(value)) return false;
  return (
    typeof value.protocolVersion === "number" &&
    typeof value.packageName === "string" &&
    typeof value.processName === "string" &&
    typeof value.pid === "number" &&
    typeof value.serverStartWallMs === "number" &&
    typeof value.serverStartMonoNs === "number" &&
    typeof value.mode === "string" &&
    (value.icon == null || isAppIcon(value.icon))
  );
}

function isAppIcon(value: unknown): value is SnapOAppIcon {
  if (!isRecord(value)) return false;
  return typeof value.width === "number" && typeof value.height === "number" && typeof value.base64Data === "string";
}

function isCdpMessage(value: unknown): value is CdpMessage {
  return isRecord(value) && (typeof value.method === "string" || typeof value.id === "number");
}

const MaxNdjsonLineChars = 16 * 1024 * 1024;
