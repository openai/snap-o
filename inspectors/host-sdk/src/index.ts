import { invokeNative, listenWebKitEvent } from "./bridge";

export type ToolbarIcon = "clear" | "sortAscending" | "sortDescending" | "search" | "export" | "reset";

export type ToolbarAction =
  | {
      type: "button";
      id: string;
      icon: ToolbarIcon;
      label: string;
      enabled?: boolean;
      onClick: () => void;
    }
  | {
      type: "search";
      id: string;
      label: string;
      value: string;
      enabled?: boolean;
      onChange: (value: string) => void;
    };

export interface Toolbar {
  start: readonly ToolbarAction[];
  end?: readonly ToolbarAction[];
}

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

export interface InspectorDescriptor {
  id: string;
  name: string;
  protocolVersion: number;
  iconBase64?: string;
}

export interface ProcessManifest {
  version: number;
  pid: number;
  processName?: string;
  androidUserId?: number;
  processIdentity: string;
  app: {
    packageName: string;
    name: string;
    revision: string;
    iconBase64?: string;
    inspectors: InspectorDescriptor[];
  };
}

export interface Host extends EventTarget {
  readonly connected: boolean;
  readonly baseURL: string | null;
  readonly manifest: ProcessManifest | null;
  readonly inspector: InspectorDescriptor | null;
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
  manifest?: ProcessManifest | null;
  inspector?: InspectorDescriptor | null;
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

// The transport is injectable for tests; inspector code uses the singleton below.
export class InspectorHost extends EventTarget implements Host {
  private state: HostState = { revision: -1, connected: false };
  private startup: Promise<void> | undefined;
  private listening = false;
  private toolbarRevision = 0;
  private nextToolbarRevision = 0;
  private acceptedToolbar = { revision: 0, actions: [] as readonly ToolbarAction[] };
  private actions: readonly ToolbarAction[] = [];
  private searchRevisions = new Map<string, number>();
  private searchStartRevisions = new Map<string, number>();
  private picker: PickerSession | undefined;

  constructor(private transport: HostTransport = { request: invokeNative, listen: listenWebKitEvent }) {
    super();
  }

  get connected(): boolean {
    void this.start().catch(() => {});
    return this.state.connected;
  }

  get baseURL(): string | null {
    void this.start().catch(() => {});
    return this.state.baseURL ?? null;
  }

  get manifest(): ProcessManifest | null {
    void this.start().catch(() => {});
    return this.state.manifest ?? null;
  }

  get inspector(): InspectorDescriptor | null {
    void this.start().catch(() => {});
    return this.state.inspector ?? null;
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
    const actions = [...toolbar.start, ...(toolbar.end ?? [])];
    if (
      toolbar.start.length > 3 ||
      toolbar.end?.some((action) => action.type === "search") ||
      actions.filter((action) => action.type === "search").length > 1 ||
      new Set(actions.map((action) => action.id)).size !== actions.length
    ) {
      throw new Error(
        "A toolbar supports up to three start actions, including one search field, and end buttons with unique IDs."
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
          placement: index < toolbar.start.length ? "start" : "end",
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
    if (changed) this.dispatchEvent(new ConnectionEvent(state.connected));
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

export const host: Host = new InspectorHost();
