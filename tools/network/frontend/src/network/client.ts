import type { Host, ToolConnection } from "@snap-o/tool-host";
import type { LoadBodiesInput, RequestBodies, StreamEvent, StreamStarted, StreamClosed } from "./bridge-types";
import { host } from "@snap-o/tool-host";
import { NetworkConnection } from "./connection";

export interface NetworkClient extends ToolContentClient {
  listExclusionFilters(): string[];
  addExclusionFilter(filter: string): void;
  removeExclusionFilter(filter: string): void;
  loadBodies(input: LoadBodiesInput): Promise<RequestBodies>;
  startStream(input: ToolConnection): Promise<StreamStarted>;
  stopStream(streamId: string): Promise<void>;
  onEvent(callback: (event: StreamEvent) => void): () => void;
  onClosed(callback: (event: StreamClosed) => void): () => void;
  dispose(): void;
}

export type ToolContentClient = Pick<Host, "copyText" | "saveFile">;

export function createNetworkClient(): NetworkClient {
  return new BrowserNetworkClient();
}

class BrowserNetworkClient implements NetworkClient {
  private active: NetworkConnection | undefined;
  private disposed = false;
  private events = new Set<(event: StreamEvent) => void>();
  private closedListeners = new Set<(event: StreamClosed) => void>();
  private closeConnection = () => {
    const connection = this.active;
    this.active = undefined;
    connection?.close();
  };

  private readonly unsubscribe = host.onConnection(() => this.closeConnection);
  dispose(): void {
    this.disposed = true;
    this.unsubscribe();
  }

  listExclusionFilters(): string[] {
    return readExclusionFilters();
  }
  addExclusionFilter(filter: string): void {
    localStorage.setItem(
      "network.exclusionFilters",
      JSON.stringify([...new Set([...readExclusionFilters(), filter])].sort())
    );
  }
  removeExclusionFilter(filter: string): void {
    localStorage.setItem(
      "network.exclusionFilters",
      JSON.stringify(readExclusionFilters().filter((item) => item !== filter))
    );
  }

  loadBodies(input: LoadBodiesInput): Promise<RequestBodies> {
    const connection = this.active;
    if (!connection) return Promise.reject(new Error("Tool is disconnected."));
    return connection.loadBodies(input);
  }
  async startStream(input: ToolConnection): Promise<StreamStarted> {
    if (this.disposed || input.signal.aborted) throw new Error("Tool is disconnected.");
    this.closeConnection();
    const connection = new NetworkConnection(
      input,
      (event) => {
        for (const listener of this.events) listener(event);
      },
      (event) => {
        if (this.active?.id === event.streamId) {
          this.active = undefined;
        }
        for (const listener of this.closedListeners) listener(event);
      }
    );
    this.active = connection;
    await connection.start();
    return { streamId: connection.id };
  }
  async stopStream(streamId: string): Promise<void> {
    if (this.active?.id === streamId) this.closeConnection();
  }
  onEvent(callback: (event: StreamEvent) => void): () => void {
    this.events.add(callback);
    return () => this.events.delete(callback);
  }
  onClosed(callback: (event: StreamClosed) => void): () => void {
    this.closedListeners.add(callback);
    return () => this.closedListeners.delete(callback);
  }
  copyText(text: string): Promise<void> {
    return host.copyText(text);
  }
  saveFile: ToolContentClient["saveFile"] = (input) => host.saveFile(input);
}

function readExclusionFilters(): string[] {
  try {
    const stored: unknown = JSON.parse(localStorage.getItem("network.exclusionFilters") ?? "[]");
    return Array.isArray(stored) ? stored.filter((item): item is string => typeof item === "string") : [];
  } catch {
    return [];
  }
}
