import type {
  AppInspectorKind,
  AppInspectorOption,
  AppInspectorState,
  InspectableApp,
  SelectedAppInspector
} from "../../network/bridge-types";

interface InspectorPreference {
  deviceId: string;
  processName: string;
  androidUserId?: number | null;
  kind: AppInspectorKind;
}

interface SavedPreferences {
  last: InspectorPreference | null;
  apps: InspectorPreference[];
}

function identity(app: InspectableApp): string | null {
  // Native discovery supplies the real process name, never a temporary display label.
  return app.processName || null;
}

function matches(app: InspectableApp, preference: InspectorPreference): boolean {
  return (
    app.deviceId === preference.deviceId &&
    (app.androidUserId ?? null) === (preference.androidUserId ?? null) &&
    identity(app) === preference.processName
  );
}

function sameApp(a: InspectableApp | null, b: InspectableApp): boolean {
  if (!a || a.deviceId !== b.deviceId) return false;
  // An unknown user can become known only for the same process ID.
  if ((a.androidUserId ?? null) !== (b.androidUserId ?? null) && (a.androidUserId != null || a.id !== b.id))
    return false;
  const first = identity(a);
  const second = identity(b);
  return first && second ? first === second : a.id === b.id;
}

function samePreference(a: InspectorPreference, b: InspectorPreference): boolean {
  return (
    a.deviceId === b.deviceId &&
    (a.androidUserId ?? null) === (b.androidUserId ?? null) &&
    a.processName === b.processName
  );
}

function isPreference(value: unknown): value is InspectorPreference {
  if (value == null || typeof value !== "object") return false;
  const p = value as Partial<InspectorPreference>;
  return (
    typeof p.deviceId === "string" &&
    typeof p.processName === "string" &&
    p.processName.length > 0 &&
    (p.androidUserId == null || (Number.isInteger(p.androidUserId) && p.androidUserId >= 0)) &&
    (p.kind === "network" || p.kind === "tweaks")
  );
}

export class InspectorRestoration {
  private saved: SavedPreferences = { last: null, apps: [] };
  private target: InspectableApp | null = null;
  private kind: AppInspectorKind | null = null;
  private current: SelectedAppInspector | null = null;
  private retained: Partial<Record<AppInspectorKind, SelectedAppInspector>> = {};
  private apps: InspectableApp[] = [];
  private awaitingAppIdentity = false;

  constructor(raw: string | null = null) {
    try {
      const parsed: unknown = raw == null ? null : JSON.parse(raw);
      if (parsed && typeof parsed === "object" && "apps" in parsed && Array.isArray(parsed.apps)) {
        this.saved.apps = parsed.apps.filter(isPreference);
        if ("last" in parsed && isPreference(parsed.last)) {
          this.saved.last = parsed.last;
          this.kind = parsed.last.kind;
        }
      }
    } catch {
      /* Ignore stale or invalid saved preferences. */
    }
  }

  serialize(): string {
    return JSON.stringify(this.saved);
  }

  hydrate(raw: string | null): void {
    if (this.kind != null || this.awaitingAppIdentity) return;
    const restored = new InspectorRestoration(raw);
    this.saved = restored.saved;
    this.kind = restored.kind;
  }

  snapshot(): AppInspectorState {
    return {
      apps: this.apps,
      selection: this.current,
      displayedNetwork: this.kind === "network" ? (this.retained.network ?? null) : null,
      displayedTweaks: this.kind === "tweaks" ? (this.retained.tweaks ?? null) : null,
      selectedApp: this.target,
      preferredKind: this.kind,
      isRestoring:
        this.awaitingAppIdentity ||
        (this.current == null && (this.kind != null || this.apps.some((app) => app.inspectors.length > 0)))
    };
  }

  reconcile(apps: InspectableApp[]): AppInspectorState {
    this.apps = apps;
    if (this.awaitingAppIdentity) {
      const app = apps.find((candidate) => candidate.id === this.target?.id);
      if (app) {
        this.updateTarget(app);
        if (identity(app)) return this.selectApp(app);
      }
      return this.snapshot();
    }
    const preference = this.saved.last;
    const exact = this.target && apps.find((app) => app.id === this.target?.id && sameApp(this.target, app));
    const app = exact || (preference && apps.find((candidate) => matches(candidate, preference)));

    if (app && this.kind) {
      this.updateTarget(app);
      this.remember(app, this.kind);
      const option = app.inspectors.find((candidate) => candidate.kind === this.kind);
      this.setCurrent(app, option);
    } else if (this.kind == null) {
      const first = apps.find((candidate) => identity(candidate) && candidate.inspectors.length > 0);
      if (first) this.selectApp(first);
    } else {
      this.current = null;
    }
    return this.snapshot();
  }

  selectApp(app: InspectableApp): AppInspectorState {
    if (!identity(app)) {
      this.updateTarget(app);
      this.current = null;
      this.retained = {};
      this.awaitingAppIdentity = true;
      return this.snapshot();
    }
    const preference = this.saved.apps.find((candidate) => matches(app, candidate));
    const kind =
      preference?.kind ?? app.inspectors.find((option) => option.kind === this.kind)?.kind ?? app.inspectors[0]?.kind;
    if (kind) this.selectKind(app, kind);
    return this.snapshot();
  }

  selectInspector(app: InspectableApp, option: AppInspectorOption): AppInspectorState {
    this.selectKind(app, option.kind);
    return this.snapshot();
  }

  private selectKind(app: InspectableApp, kind: AppInspectorKind): void {
    if (!sameApp(this.target, app)) this.retained = {};
    this.awaitingAppIdentity = false;
    this.updateTarget(app);
    this.kind = kind;
    // An explicit choice supersedes pending restoration, even before metadata arrives.
    this.saved.last = null;
    this.remember(app, kind);
    // Cached toolbar options express intent, never permission to reuse an old socket.
    const liveApp = this.apps.find((candidate) => candidate.id === app.id && sameApp(app, candidate));
    const option = liveApp?.inspectors.find((candidate) => candidate.kind === kind);
    this.setCurrent(liveApp ?? app, option);
  }

  private updateTarget(app: InspectableApp): void {
    const options = new Map<AppInspectorKind, AppInspectorOption>();
    const previous = this.target;
    if (previous && sameApp(previous, app)) {
      for (const option of previous.inspectors) options.set(option.kind, option);
    }
    for (const option of app.inspectors) options.set(option.kind, option);
    this.target = { ...app, inspectors: [...options.values()].sort((a, b) => a.kind.localeCompare(b.kind)) };
  }

  private setCurrent(app: InspectableApp, option: AppInspectorOption | undefined): void {
    if (!option) {
      this.current = null;
      return;
    }
    if (
      this.current?.appId === app.id &&
      this.current.kind === option.kind &&
      this.current.server.deviceId === option.server.deviceId &&
      this.current.server.socketName === option.server.socketName &&
      this.current.protocolVersion === option.protocolVersion
    )
      return;
    this.current = { appId: app.id, ...option };
    this.retained[option.kind] = this.current;
  }

  private remember(app: InspectableApp, kind: AppInspectorKind): void {
    const processName = identity(app);
    if (!processName) return;
    const preference = { deviceId: app.deviceId, processName, androidUserId: app.androidUserId, kind };
    this.saved.last = preference;
    this.saved.apps = [...this.saved.apps.filter((entry) => !samePreference(entry, preference)), preference];
  }
}
