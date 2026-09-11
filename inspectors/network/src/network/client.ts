import type { InspectorMetadata } from "../features/app-inspector/useInspectorMetadata";
import type {
  LoadBodiesInput,
  RequestBodies,
  SaveFileInput,
  SaveFileResult,
  StreamEvent,
  StreamStarted,
  StreamStatus
} from "./bridge-types";
import { host } from "@snap-o/host";
import { NetworkConnection } from "./connection";
import { version } from "../../package.json";

export interface NetworkClient {
  appVersion(): Promise<string>;
  listExclusionFilters(): Promise<string[]>;
  addExclusionFilter(filter: string): Promise<void>;
  removeExclusionFilter(filter: string): Promise<void>;
  loadBodies(input: LoadBodiesInput): Promise<RequestBodies>;
  startStream(input: InspectorMetadata): Promise<StreamStarted>;
  stopStream(streamId: string): Promise<void>;
  onEvent(callback: (event: StreamEvent) => void): () => void;
  onStatus(callback: (status: StreamStatus) => void): () => void;
  copyText(text: string): Promise<void>;
  openExternal(url: string): Promise<void>;
  saveFile(input: SaveFileInput): Promise<SaveFileResult>;
  dispose(): void;
}

export type InspectorContentClient = Pick<NetworkClient, "copyText" | "saveFile">;

export function createNetworkClient(): NetworkClient {
  return new BrowserNetworkClient();
}

class BrowserNetworkClient implements NetworkClient {
  private connections = new Map<string, NetworkConnection>();
  private events = new Set<(event: StreamEvent) => void>();
  private statuses = new Set<(status: StreamStatus) => void>();
  private disconnected = () => {
    for (const connection of this.connections.values()) connection.close();
    this.connections.clear();
  };

  constructor() {
    host.addEventListener("connection", this.disconnected);
  }
  dispose(): void {
    host.removeEventListener("connection", this.disconnected);
    for (const connection of this.connections.values()) connection.close();
    this.connections.clear();
  }
  appVersion(): Promise<string> {
    return Promise.resolve(version);
  }

  async listExclusionFilters(): Promise<string[]> {
    return readExclusionFilters();
  }
  async addExclusionFilter(filter: string): Promise<void> {
    localStorage.setItem(
      "network.exclusionFilters",
      JSON.stringify([...new Set([...readExclusionFilters(), filter])].sort())
    );
  }
  async removeExclusionFilter(filter: string): Promise<void> {
    localStorage.setItem(
      "network.exclusionFilters",
      JSON.stringify(readExclusionFilters().filter((item) => item !== filter))
    );
  }

  loadBodies(input: LoadBodiesInput): Promise<RequestBodies> {
    const connection = this.connections.values().next().value;
    if (!connection) return Promise.reject(new Error("Inspector is disconnected."));
    return connection.loadBodies(input);
  }
  async startStream(input: InspectorMetadata): Promise<StreamStarted> {
    if (!host.connected || !host.baseURL) throw new Error("Inspector is disconnected.");
    for (const connection of this.connections.values()) connection.close();
    this.connections.clear();
    const connection = new NetworkConnection(
      host.baseURL,
      input,
      (event) => {
        for (const listener of this.events) listener(event);
      },
      (status) => {
        if (status.state === "exit" || status.state === "error") this.connections.delete(status.streamId);
        for (const listener of this.statuses) listener(status);
      }
    );
    this.connections.set(connection.id, connection);
    try {
      await connection.start();
    } catch (error) {
      connection.close();
      throw error;
    }
    return { streamId: connection.id };
  }
  async stopStream(streamId: string): Promise<void> {
    this.connections.get(streamId)?.close();
    this.connections.delete(streamId);
  }
  onEvent(callback: (event: StreamEvent) => void): () => void {
    this.events.add(callback);
    return () => this.events.delete(callback);
  }
  onStatus(callback: (status: StreamStatus) => void): () => void {
    this.statuses.add(callback);
    return () => this.statuses.delete(callback);
  }
  copyText(text: string): Promise<void> {
    return host.copyText(text);
  }
  async openExternal(url: string): Promise<void> {
    openInspectorLink(url);
  }
  async saveFile(input: SaveFileInput): Promise<SaveFileResult> {
    const data =
      input.encoding === "base64" ? Uint8Array.from(atob(input.data), (char) => char.charCodeAt(0)) : input.data;
    return {
      saved: await host.saveFile({
        name: input.defaultPath,
        data: new Blob([data], { type: input.mimeType ?? "application/octet-stream" })
      })
    };
  }
}

export function openInspectorLink(url: string): void {
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.click();
}

function readExclusionFilters(): string[] {
  try {
    const stored: unknown = JSON.parse(localStorage.getItem("network.exclusionFilters") ?? "[]");
    return Array.isArray(stored) ? stored.filter((item): item is string => typeof item === "string") : [];
  } catch {
    return [];
  }
}
