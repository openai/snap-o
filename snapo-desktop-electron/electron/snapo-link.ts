import type { Duplex } from "node:stream";
import type { CdpMessage } from "../src/network/bridge-types.js";

export interface LinkFeatureInfo {
  id: string;
}

export interface HelloRecord {
  type: "Hello";
  schemaVersion?: number | null;
  packageName: string;
  processName: string;
  pid: number;
  serverStartWallMs: number;
  serverStartMonoNs: number;
  mode: string;
  features?: LinkFeatureInfo[];
}

export interface AppIconRecord {
  type: "AppIcon";
  packageName: string;
  width: number;
  height: number;
  format?: string;
  base64Data: string;
}

export type SnapORecord =
  | { kind: "hello"; value: HelloRecord }
  | { kind: "appIcon"; value: AppIconRecord }
  | { kind: "replayComplete" }
  | { kind: "network"; value: CdpMessage }
  | { kind: "unknown"; type: string; rawJson: string };

export class SnapOLinkConnection {
  private lineBuffer = "";
  private skippingOversizedLine = false;
  private stopped = false;

  constructor(
    private readonly stream: Duplex,
    private readonly onRecord: (record: SnapORecord) => void,
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
    this.stream.write("HelloSnapO\n", "utf8");
  }

  stop(): void {
    this.stopped = true;
    this.stream.destroy();
  }

  sendFeatureOpened(feature: string): void {
    this.sendHostMessage({
      type: "FeatureOpened",
      feature
    });
  }

  sendFeatureCommand(feature: string, payload: CdpMessage): void {
    this.sendHostMessage({
      type: "FeatureCommand",
      feature,
      payload
    });
  }

  private sendHostMessage(message: Record<string, unknown>): void {
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
    this.onRecord(decodeSnapOLine(line));
  }
}

function decodeSnapOLine(line: string): SnapORecord {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch {
    return { kind: "unknown", type: "<unparseable>", rawJson: line };
  }

  if (!isRecord(value)) {
    return { kind: "unknown", type: "<non-object>", rawJson: line };
  }

  const type = typeof value.type === "string" ? value.type : "<missing-type>";
  if (type === "Hello" && isHelloRecord(value)) {
    return { kind: "hello", value };
  }
  if (type === "AppIcon" && isAppIconRecord(value)) {
    return { kind: "appIcon", value };
  }
  if (type === "ReplayComplete") {
    return { kind: "replayComplete" };
  }
  if (type === "FeatureEvent" && value.feature === "network" && isRecord(value.payload)) {
    return { kind: "network", value: value.payload as unknown as CdpMessage };
  }

  return { kind: "unknown", type, rawJson: line };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

function isHelloRecord(value: unknown): value is HelloRecord {
  if (!isRecord(value)) return false;
  return (
    typeof value.packageName === "string" && typeof value.processName === "string" && typeof value.pid === "number"
  );
}

function isAppIconRecord(value: unknown): value is AppIconRecord {
  if (!isRecord(value)) return false;
  return (
    typeof value.packageName === "string" &&
    typeof value.width === "number" &&
    typeof value.height === "number" &&
    typeof value.base64Data === "string"
  );
}

const MaxNdjsonLineChars = 16 * 1024 * 1024;
