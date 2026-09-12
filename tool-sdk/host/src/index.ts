import { invokeNative, listenWebKitEvent } from "./bridge.js";

export type ToolbarIcon = "clear" | "sortAscending" | "sortDescending" | "search" | "export" | "reset";

export interface ToolbarAction {
  id: string;
  icon: ToolbarIcon;
  label: string;
  enabled?: boolean;
  onClick: () => void;
}

export interface ToolbarSearch {
  label: string;
  value: string;
  enabled?: boolean;
  onChange: (value: string) => void;
}

export interface Toolbar {
  actions?: readonly ToolbarAction[];
  search?: ToolbarSearch;
  endActions?: readonly ToolbarAction[];
}

type ToolbarItem = (ToolbarAction & { type: "button" }) | (ToolbarSearch & { type: "search"; id: string });

export interface ColorPickerOptions {
  value: string;
  onChange: (value: string) => void;
  onClose?: () => void;
}

export interface ColorPicker {
  setValue(value: string): Promise<void>;
  close(): Promise<void>;
}

export class ConnectionEvent extends Event {
  constructor(readonly connected: boolean) {
    super("connection");
  }
}

export interface ToolConnection {
  readonly baseURL: string;
  readonly protocolVersion: number;
  readonly processIdentity: string;
  readonly signal: AbortSignal;
}

export interface Host extends EventTarget {
  readonly connection: ToolConnection | null;
  onConnection(callback: (connection: ToolConnection | null) => void | (() => void)): () => void;
  addEventListener(
    type: "connection",
    callback: (event: ConnectionEvent) => void,
    options?: boolean | AddEventListenerOptions
  ): void;
  addEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | null,
    options?: boolean | AddEventListenerOptions
  ): void;
  removeEventListener(
    type: "connection",
    callback: (event: ConnectionEvent) => void,
    options?: boolean | EventListenerOptions
  ): void;
  removeEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | null,
    options?: boolean | EventListenerOptions
  ): void;
  setToolbar(toolbar: Toolbar): Promise<void>;
  openColorPicker(options: ColorPickerOptions): Promise<ColorPicker>;
  copyText(text: string): Promise<void>;
  saveFile(options: { name: string; data: Blob }): Promise<boolean>;
}

interface HostState {
  revision: number;
  connected: boolean;
  baseURL?: string | null;
  manifest?: { processIdentity: string } | null;
  inspector?: { protocolVersion: number } | null;
}

interface ToolbarEvent {
  revision: number;
  id: string;
  value?: string;
  inputRevision?: number;
}

interface PickerSession {
  id: string;
  options: ColorPickerOptions;
  closed: boolean;
  revision: number;
}

interface HostTransport {
  request<T>(command: string, payload?: unknown): Promise<T>;
  listen<T>(name: string, callback: (payload: T) => void): () => void;
}

// The transport is injectable for tests; tool code uses the singleton below.
export class ToolHost extends EventTarget implements Host {
  private currentConnection: ToolConnection | null = null;
  private connectionController: AbortController | undefined;
  private state: HostState = { revision: -1, connected: false };
  private startup: Promise<void> | undefined;
  private listening = false;
  private toolbarRevision = 0;
  private nextToolbarRevision = 0;
  private acceptedToolbar = { revision: 0, actions: [] as readonly ToolbarItem[] };
  private actions: readonly ToolbarItem[] = [];
  private searchRevisions = new Map<string, number>();
  private searchStartRevisions = new Map<string, number>();
  private picker: PickerSession | undefined;

  constructor(private transport: HostTransport = { request: invokeNative, listen: listenWebKitEvent }) {
    super();
  }

  get connection(): ToolConnection | null {
    void this.start().catch(() => {});
    return this.currentConnection;
  }

  onConnection(callback: (connection: ToolConnection | null) => void | (() => void)): () => void {
    let cleanup: void | (() => void);
    const update = () => {
      cleanup?.();
      cleanup = undefined;
      cleanup = callback(this.connection);
    };
    this.addEventListener("connection", update);
    update();
    return () => {
      this.removeEventListener("connection", update);
      cleanup?.();
      cleanup = undefined;
    };
  }

  override addEventListener(
    type: "connection",
    callback: (event: ConnectionEvent) => void,
    options?: boolean | AddEventListenerOptions
  ): void;
  override addEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | null,
    options?: boolean | AddEventListenerOptions
  ): void;
  override addEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | ((event: ConnectionEvent) => void) | null,
    options?: boolean | AddEventListenerOptions
  ): void {
    super.addEventListener(type, callback as EventListenerOrEventListenerObject | null, options);
    void this.start().catch(() => {});
  }

  override removeEventListener(
    type: "connection",
    callback: (event: ConnectionEvent) => void,
    options?: boolean | EventListenerOptions
  ): void;
  override removeEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | null,
    options?: boolean | EventListenerOptions
  ): void;
  override removeEventListener(
    type: string,
    callback: EventListenerOrEventListenerObject | ((event: ConnectionEvent) => void) | null,
    options?: boolean | EventListenerOptions
  ): void {
    super.removeEventListener(type, callback as EventListenerOrEventListenerObject | null, options);
  }

  async setToolbar(toolbar: Toolbar): Promise<void> {
    await this.start();
    const start: ToolbarItem[] = (toolbar.actions ?? []).map((action) => ({ ...action, type: "button" }));
    if (toolbar.search) start.push({ ...toolbar.search, type: "search", id: "search" });
    const end: ToolbarItem[] = (toolbar.endActions ?? []).map((action) => ({ ...action, type: "button" }));
    const actions = [...start, ...end];
    if (
      start.length > 3 ||
      actions.length > 11 ||
      new Set(actions.map((action) => action.id)).size !== actions.length
    ) {
      throw new Error(
        "A toolbar supports up to three main controls including search, eleven controls total, and unique action IDs. The ID 'search' is reserved when search is present."
      );
    }
    const revision = ++this.nextToolbarRevision;
    this.toolbarRevision = revision;
    for (const action of actions) {
      if (
        action.type === "search" &&
        !this.actions.some((previous) => previous.id === action.id && previous.type === "search")
      ) {
        this.searchStartRevisions.set(action.id, revision);
        this.searchRevisions.delete(action.id);
      }
    }
    this.actions = actions;
    try {
      await this.transport.request("setToolbar", {
        revision,
        actions: actions.map((action, index) => ({
          placement: index < start.length ? "start" : "end",
          type: action.type,
          id: action.id,
          label: action.label,
          enabled: action.enabled ?? true,
          ...(action.type === "button"
            ? { icon: action.icon }
            : { value: action.value, inputRevision: this.searchRevisions.get(action.id) ?? 0 })
        }))
      });
      if (revision > this.acceptedToolbar.revision) this.acceptedToolbar = { revision, actions };
    } catch (error) {
      if (this.toolbarRevision === revision) {
        this.actions = this.acceptedToolbar.actions;
        this.toolbarRevision = this.acceptedToolbar.revision;
      }
      throw error;
    }
  }

  async openColorPicker(options: ColorPickerOptions): Promise<ColorPicker> {
    await this.start();
    this.finishPicker();
    const picker: PickerSession = { id: crypto.randomUUID(), options, closed: false, revision: 0 };
    this.picker = picker;
    try {
      await this.transport.request("openNativeColorPanel", {
        color: options.value,
        sessionId: picker.id,
        revision: picker.revision
      });
    } catch (error) {
      if (this.picker === picker) this.finishPicker();
      throw error;
    }
    if (picker.closed) throw new DOMException("Color picker closed.", "AbortError");
    return {
      setValue: async (value) => {
        if (picker.closed) return;
        const revision = ++picker.revision;
        await this.transport.request("openNativeColorPanel", {
          color: value,
          sessionId: picker.id,
          revision,
          present: false
        });
      },
      close: async () => {
        if (picker.closed) return;
        if (this.picker === picker) this.finishPicker();
        await this.transport.request("closeNativeColorPanel", { sessionId: picker.id });
      }
    };
  }

  async copyText(text: string): Promise<void> {
    await this.transport.request("copyText", { text });
  }

  async saveFile({ name, data }: { name: string; data: Blob }): Promise<boolean> {
    const bytes = new Uint8Array(await data.arrayBuffer());
    const parts: string[] = [];
    for (let offset = 0; offset < bytes.length; offset += 8192) {
      parts.push(String.fromCharCode(...bytes.subarray(offset, offset + 8192)));
    }
    const result = await this.transport.request<{ saved: boolean }>("saveFile", {
      defaultPath: name,
      data: btoa(parts.join("")),
      encoding: "base64",
      mimeType: data.type
    });
    return result.saved;
  }

  private start(): Promise<void> {
    if (!this.listening) {
      this.listening = true;
      this.transport.listen<HostState>("host:connection", (state) => this.updateState(state));
      this.transport.listen<ToolbarEvent>("host:toolbar", (event) => this.toolbarEvent(event));
      this.transport.listen<{ sessionId: string; color: string; revision: number }>("host:color-changed", (event) => {
        if (this.picker?.id === event.sessionId && this.picker.revision === event.revision)
          this.picker.options.onChange(event.color);
      });
      this.transport.listen<string>("host:color-closed", (id) => {
        if (this.picker?.id === id) this.finishPicker();
      });
    }
    if (!this.startup) {
      this.startup = this.transport
        .request<HostState>("hostState")
        .then((state) => this.updateState(state))
        .catch((error) => {
          this.startup = undefined;
          throw error;
        });
    }
    return this.startup;
  }

  private updateState(state: HostState): void {
    if (state.revision <= this.state.revision) return;
    // A new connection may reuse the same forwarded port.
    const changed =
      state.connected ||
      state.connected !== this.state.connected ||
      state.baseURL !== this.state.baseURL ||
      state.manifest !== this.state.manifest ||
      state.inspector !== this.state.inspector;
    this.state = state;
    this.connectionController?.abort();
    const protocolVersion = state.inspector?.protocolVersion;
    const processIdentity = state.manifest?.processIdentity;
    const ready = state.connected && state.baseURL && protocolVersion != null && processIdentity;
    this.connectionController = ready ? new AbortController() : undefined;
    this.currentConnection =
      ready && this.connectionController
        ? { baseURL: state.baseURL!, protocolVersion, processIdentity, signal: this.connectionController.signal }
        : null;
    if (changed) this.dispatchEvent(new ConnectionEvent(this.currentConnection !== null));
  }

  private toolbarEvent(event: ToolbarEvent): void {
    const action = this.actions.find((item) => item.id === event.id);
    if (!action || action.enabled === false) return;
    if (action.type === "button") {
      if (event.revision === this.toolbarRevision) action.onClick();
    } else if (
      event.revision >= (this.searchStartRevisions.get(action.id) ?? 0) &&
      typeof event.value === "string" &&
      typeof event.inputRevision === "number" &&
      event.inputRevision > (this.searchRevisions.get(action.id) ?? 0)
    ) {
      this.searchRevisions.set(action.id, event.inputRevision);
      action.onChange(event.value);
    }
  }

  private finishPicker(): void {
    const picker = this.picker;
    this.picker = undefined;
    if (!picker || picker.closed) return;
    picker.closed = true;
    picker.options.onClose?.();
  }
}

export const host: Host = new ToolHost();
