import { ChevronDown, LoaderCircle, RotateCcw } from "lucide-react";
import { useCallback, useEffect, useId, useMemo, useRef, useState, type CSSProperties } from "react";
import type {
  AppInspectorOption,
  InspectableApp,
  SelectedAppInspector,
  StreamStarted,
  TweakActionDescriptor,
  TweakDescriptor,
  TweakUpdate,
  TweakValue,
  TweakValueDescriptor
} from "../../network/bridge-types";
import type { NativeColorPanelChange, NetworkClient } from "../../network/client";
import { AppInspectorPicker } from "../app-inspector/components/AppInspectorPicker";
import { TweakUpdateQueue } from "./tweak-update-queue";

interface TweakSection {
  name: string;
  order: number;
  tweaks: TweakDescriptor[];
}

interface TweakOrdering {
  sections: Map<string, number>;
  tweaks: Map<string, number>;
}

interface ActiveColorPanelSession {
  tweak: TweakValueDescriptor;
  sessionId: string;
}

let nextColorPanelSession = 0;
const docsUrl = "https://openai.github.io/snap-o/tweaks.html#expose-values";
const modifiedTweakProtocolVersion = 4;

export function TweaksInspectorApp({
  client,
  apps,
  selection,
  selectedApp,
  isConnected = true,
  onSelect
}: {
  client: NetworkClient;
  apps: InspectableApp[];
  selection: SelectedAppInspector;
  selectedApp?: InspectableApp | null;
  isConnected?: boolean;
  onSelect(app: InspectableApp, option?: AppInspectorOption): void;
}): JSX.Element {
  const server = selection.server;
  const connection = useMemo(() => ({ server, isConnected }), [isConnected, server]);
  const [tweaks, setTweaks] = useState<TweakDescriptor[]>([]);
  const [hasSnapshot, setHasSnapshot] = useState(false);
  const [connectionState, setConnectionState] = useState<{
    connection: typeof connection;
    error: string | null;
  } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [invokingActions, setInvokingActions] = useState(() => new Set<string>());
  const [orderByApp] = useState(() => new Map<string, TweakOrdering>());
  const activeColorPanel = useRef<ActiveColorPanelSession | null>(null);
  const currentConnection = connectionState?.connection === connection ? connectionState : null;
  const canEdit = isConnected && currentConnection?.error === null;
  const connectionError = currentConnection?.error ?? null;
  const protocolVersion = selection.protocolVersion ?? 1;
  const hasNativeColorPanel =
    client.usesNativeServerPicker &&
    typeof client.openNativeColorPanel === "function" &&
    typeof client.onNativeColorPanelChange === "function";
  const queue = useMemo(
    () =>
      new TweakUpdateQueue(client, server, {
        onUpdate(updates, pending) {
          setTweaks((current) => applyTweakUpdates(current, updates, pending, protocolVersion));
        },
        onRejected(_errors, pending, inFlight, isCurrent) {
          void client
            .listTweaks(server)
            .then((response) => {
              if (!isCurrent()) return;
              setTweaks((current) => reconcileStreamedTweaks(current, response.tweaks, pending, inFlight));
              setError(null);
            })
            .catch((cause: unknown) => {
              if (!isCurrent()) return;
              setError(cause instanceof Error ? cause.message : "Unable to reload tweaks.");
            });
        },
        onError: setError,
        onSavingChange: setSaving
      }),
    [client, protocolVersion, server]
  );

  useEffect(() => {
    if (!isConnected) return;
    let disposed = false;
    let streamStart: Promise<StreamStarted> | undefined;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
    let retryDelay = 250;

    const applySnapshot = (incoming: TweakDescriptor[]) => {
      setTweaks((current) => reconcileStreamedTweaks(current, incoming, queue.pending, queue.inFlight));
      setHasSnapshot(true);
      setError(null);
    };

    const unsubscribe = client.onTweaksChanged((event) => {
      if (disposed || event.server.deviceId !== server.deviceId || event.server.socketName !== server.socketName) {
        return;
      }

      // The initial event can arrive before the start reply identifies its stream.
      void streamStart?.then(
        ({ streamId }) => {
          if (disposed || event.streamId !== streamId) return;
          applySnapshot(event.tweaks);
          setConnectionState({ connection, error: null });
        },
        () => {}
      );
    });

    const connect = async () => {
      try {
        const response = await client.listTweaks(server);
        if (disposed) return;
        applySnapshot(response.tweaks);
        setConnectionState(null);
        setSaving(false);

        streamStart = client.startTweakStream(server);
        await streamStart;
        if (disposed) return;
        setConnectionState({ connection, error: null });
      } catch (cause) {
        if (disposed) return;
        setConnectionState({
          connection,
          error: cause instanceof Error ? cause.message : "Unable to connect to tweaks."
        });
        retryTimer = setTimeout(() => void connect(), retryDelay);
        retryDelay = Math.min(retryDelay * 2, 4_000);
      }
    };
    void connect();

    return () => {
      disposed = true;
      clearTimeout(retryTimer);
      queue.cancel();
      unsubscribe();
      void streamStart?.then(({ streamId }) => client.stopTweakStream(streamId)).catch(() => {});
    };
  }, [client, connection, isConnected, queue, server]);

  const closeActiveColorPanel = useCallback(async () => {
    const active = activeColorPanel.current;
    activeColorPanel.current = null;
    if (active) await client.closeNativeColorPanel?.(active.sessionId);
  }, [client]);

  useEffect(() => {
    if (!canEdit) void closeActiveColorPanel().catch(() => {});
  }, [canEdit, closeActiveColorPanel]);

  const openNativeColorPanel = useCallback(
    (tweak: TweakValueDescriptor, present = true) => {
      if (!canEdit || !hasNativeColorPanel || client.openNativeColorPanel === undefined) {
        activeColorPanel.current = null;
        return;
      }

      const sessionId = String(++nextColorPanelSession);
      activeColorPanel.current = { tweak, sessionId };
      void client.openNativeColorPanel(String(tweak.value), sessionId, present).catch((cause: unknown) => {
        if (activeColorPanel.current?.sessionId !== sessionId) return;

        activeColorPanel.current = null;
        setError(cause instanceof Error ? cause.message : "Unable to open the color picker.");
      });
    },
    [canEdit, client, hasNativeColorPanel]
  );

  const updateTweak = useCallback(
    (tweak: TweakValueDescriptor, value: TweakValue) => {
      if (!canEdit) return;
      const active = activeColorPanel.current;
      if (active?.tweak.name === tweak.name && active.tweak.value !== value) {
        openNativeColorPanel({ ...tweak, value }, false);
      }

      setTweaks((current) =>
        current.map((item) =>
          item.name === tweak.name && item.type !== "action" ? { ...item, value, modified: true } : item
        )
      );
      queue.enqueue(tweak.name, value);
      void queue.flush();
    },
    [canEdit, openNativeColorPanel, queue]
  );

  useEffect(() => {
    const active = activeColorPanel.current;
    if (active === null) return;

    const tweak = tweaks.find((candidate) => candidate.name === active.tweak.name && candidate.type === "color");
    if (tweak === undefined || tweak.type === "action") {
      void closeActiveColorPanel().catch((cause: unknown) => {
        if (activeColorPanel.current !== null) return;

        setError(cause instanceof Error ? cause.message : "Unable to close the color picker.");
      });
      return;
    }

    if (tweak.value === active.tweak.value) {
      activeColorPanel.current = { ...active, tweak };
      return;
    }

    openNativeColorPanel(tweak, false);
  }, [closeActiveColorPanel, openNativeColorPanel, tweaks]);

  useEffect(() => {
    if (!hasNativeColorPanel || client.onNativeColorPanelChange === undefined) return;

    const unsubscribe = client.onNativeColorPanelChange((event) => {
      const active = activeColorPanel.current;
      if (active === null) return;

      const value = nativePanelTweakColor(event, active.sessionId);
      if (value === null) return;

      activeColorPanel.current = { ...active, tweak: { ...active.tweak, value } };
      updateTweak(active.tweak, value);
    });

    return () => {
      void closeActiveColorPanel().catch(() => {});
      unsubscribe();
    };
  }, [client, closeActiveColorPanel, hasNativeColorPanel, updateTweak]);

  const invokeAction = useCallback(
    (action: TweakActionDescriptor) => {
      if (!canEdit || action.conflicted) return;

      setInvokingActions((current) => new Set(current).add(action.name));
      setError(null);

      void client
        .invokeTweakAction({ server, name: action.name })
        .catch((cause: unknown) => {
          setError(cause instanceof Error ? cause.message : `Unable to invoke ${action.name}.`);
        })
        .finally(() => {
          setInvokingActions((current) => {
            const next = new Set(current);
            next.delete(action.name);
            return next;
          });
        });
    },
    [canEdit, client, server]
  );

  const resetTweak = useCallback(
    (tweak: TweakValueDescriptor) => {
      if (!canEdit) return;
      queue.enqueue(tweak.name, tweakResetValue(tweak, protocolVersion));
      void queue.flush();
    },
    [canEdit, protocolVersion, queue]
  );

  const resetAll = useCallback(() => {
    if (!canEdit) return;
    for (const tweak of tweaks) {
      if (tweak.type !== "action" && isModified(tweak, protocolVersion)) {
        queue.enqueue(tweak.name, tweakResetValue(tweak, protocolVersion));
      }
    }
    void queue.flush();
  }, [canEdit, protocolVersion, queue, tweaks]);

  useEffect(() => client.onNativeTweaksReset(resetAll), [client, resetAll]);

  const sections = useMemo(
    () => groupTweaks(tweaks, selection.appId, orderByApp),
    [orderByApp, selection.appId, tweaks]
  );
  const hasChanges = canResetTweaks(tweaks, protocolVersion);

  useEffect(() => {
    client.nativeTweaksStateChanged({
      server,
      hasResettableTweaks: canEdit && hasChanges && !saving
    });
  }, [canEdit, client, hasChanges, saving, server]);

  return (
    <main className="tweaks-inspector">
      {!client.usesNativeServerPicker ? (
        <header className="tweaks-inspector-toolbar">
          <div className="tweaks-inspector-actions">
            <button
              className="tweaks-action"
              type="button"
              title="Reset all tweaks"
              aria-label="Reset all tweaks"
              disabled={!canEdit || !hasChanges || saving}
              onClick={resetAll}
            >
              <RotateCcw size={16} aria-hidden="true" />
            </button>
          </div>
          <AppInspectorPicker apps={apps} selection={selection} selectedApp={selectedApp} onSelect={onSelect} />
        </header>
      ) : null}

      {!hasSnapshot && !connectionError ? (
        <div className="inspector-loading" role="status" aria-label="Connecting to inspector">
          <LoaderCircle className="body-loading-spinner" size={20} aria-hidden="true" />
        </div>
      ) : hasSnapshot && !error && tweaks.length === 0 ? (
        <TweaksEmptyState onOpenDocs={() => void client.openExternal(docsUrl)} />
      ) : (
        <div className="tweaks-inspector-content">
          {error || (!hasSnapshot && connectionError) ? (
            <p className="tweaks-error" role="alert">
              {error ?? connectionError}
            </p>
          ) : null}
          <fieldset
            className="tweaks-fields"
            disabled={!canEdit}
            aria-label="Tweaks"
            aria-disabled={!canEdit}
            {...(!canEdit ? { inert: "" } : {})}
          >
            <div className="tweaks-columns">
              {sections.map((column, index) => (
                <div className="tweaks-column" key={index}>
                  {column.map((section) => (
                    <section className="tweaks-section" key={section.name}>
                      {section.name ? <h2>{section.name}</h2> : null}
                      <div className="tweaks-section-list">
                        {section.tweaks.map((tweak) => (
                          <TweakControl
                            key={tweak.name}
                            tweak={tweak}
                            protocolVersion={protocolVersion}
                            onChange={updateTweak}
                            onInvoke={invokeAction}
                            invoking={invokingActions.has(tweak.name)}
                            onReset={resetTweak}
                            onOpenColorPanel={hasNativeColorPanel ? openNativeColorPanel : undefined}
                          />
                        ))}
                      </div>
                    </section>
                  ))}
                </div>
              ))}
            </div>
          </fieldset>
        </div>
      )}
    </main>
  );
}

export function TweaksEmptyState({ onOpenDocs }: { onOpenDocs(): void }): JSX.Element {
  return (
    <section className="empty-detail">
      <h1>No tweaks on screen</h1>
      <p>Add a tweak to your app’s Compose UI to see it here.</p>
      <button className="text-button" type="button" onClick={onOpenDocs}>
        Read the developer guide
      </button>
    </section>
  );
}

export function canResetTweaks(tweaks: TweakDescriptor[], protocolVersion = modifiedTweakProtocolVersion): boolean {
  return tweaks.some((tweak) => tweak.type !== "action" && isModified(tweak, protocolVersion));
}

function isModified(tweak: TweakValueDescriptor, protocolVersion: number): boolean {
  return protocolVersion < modifiedTweakProtocolVersion ? tweak.value !== tweak.default : tweak.modified === true;
}

export function tweakResetValue(
  tweak: TweakValueDescriptor,
  protocolVersion: number | null | undefined
): TweakValue | null {
  return (protocolVersion ?? 1) < modifiedTweakProtocolVersion ? tweak.default : null;
}

export function applyTweakUpdates(
  tweaks: TweakDescriptor[],
  updates: TweakUpdate[],
  pending: ReadonlyMap<string, TweakValue | null>,
  protocolVersion = modifiedTweakProtocolVersion
): TweakDescriptor[] {
  return tweaks.map((tweak) => {
    if (tweak.type === "action") return tweak;

    const update = updates.find((candidate) => candidate.name === tweak.name);
    return update && !pending.has(tweak.name)
      ? {
          ...tweak,
          value: update.value,
          modified:
            protocolVersion < modifiedTweakProtocolVersion ? update.value !== tweak.default : update.modified === true
        }
      : tweak;
  });
}

export function reconcileStreamedTweaks(
  current: TweakDescriptor[],
  incoming: TweakDescriptor[],
  pending: ReadonlyMap<string, TweakValue | null>,
  inFlight: ReadonlySet<string>
): TweakDescriptor[] {
  const currentByName = new Map(current.map((tweak) => [tweak.name, tweak]));

  return incoming.map((tweak) => {
    const existing = currentByName.get(tweak.name);
    if (
      existing &&
      existing.type !== "action" &&
      tweak.type !== "action" &&
      (pending.has(tweak.name) || inFlight.has(tweak.name))
    ) {
      return { ...tweak, value: existing.value, modified: existing.modified };
    }
    return tweak;
  });
}

export function groupTweaks(
  tweaks: TweakDescriptor[],
  appId: string,
  saved: Map<string, TweakOrdering>
): TweakSection[][] {
  let ordering = saved.get(appId);
  if (!ordering) {
    ordering = { sections: new Map(), tweaks: new Map() };
    saved.set(appId, ordering);
  }

  const active = new Map<string, TweakDescriptor[]>();

  for (const tweak of tweaks) {
    const name = tweakSection(tweak.name);
    if (!ordering.sections.has(name)) ordering.sections.set(name, ordering.sections.size);
    if (!ordering.tweaks.has(tweak.name)) ordering.tweaks.set(tweak.name, ordering.tweaks.size);
    const items = active.get(name) ?? [];
    items.push(tweak);
    active.set(name, items);
  }

  const count = Math.min(2, ordering.sections.size);
  const columns: TweakSection[][] = Array.from({ length: count }, () => []);

  for (const [name, items] of active) {
    const order = ordering.sections.get(name) ?? 0;
    const section: TweakSection = {
      name,
      order,
      tweaks: items.sort(
        (left, right) => (ordering.tweaks.get(left.name) ?? 0) - (ordering.tweaks.get(right.name) ?? 0)
      )
    };
    columns[order % count].push(section);
  }

  for (const column of columns) column.sort((left, right) => left.order - right.order);
  return columns;
}

function tweakSection(name: string): string {
  const separator = name.indexOf("/");
  if (separator <= 0 || separator === name.length - 1) return "";
  return name.slice(0, separator).trim();
}

function tweakLabel(name: string): string {
  const section = tweakSection(name);
  return section ? name.slice(name.indexOf("/") + 1).trim() : name;
}

function TweakControl({
  tweak,
  protocolVersion,
  onChange,
  onInvoke,
  invoking,
  onReset,
  onOpenColorPanel
}: {
  tweak: TweakDescriptor;
  protocolVersion: number;
  onChange(tweak: TweakValueDescriptor, value: TweakValue): void;
  onInvoke(action: TweakActionDescriptor): void;
  invoking: boolean;
  onReset(tweak: TweakValueDescriptor): void;
  onOpenColorPanel?(tweak: TweakValueDescriptor): void;
}): JSX.Element {
  if (tweak.type === "action") {
    return <TweakActionControl action={tweak} invoking={invoking} onInvoke={onInvoke} />;
  }

  const label = tweakLabel(tweak.name);
  const changed = isModified(tweak, protocolVersion);

  return (
    <div className="tweaks-control">
      <div className="tweaks-control-line">
        <span className="tweaks-control-label">{label}</span>
        {changed ? (
          <button
            className="tweaks-reset"
            type="button"
            aria-label={`Reset ${tweak.name}`}
            title={`Reset ${label}`}
            onClick={() => onReset(tweak)}
          >
            <RotateCcw size={13} aria-hidden="true" />
          </button>
        ) : null}
        <span className="tweaks-control-field">
          <TweakField tweak={tweak} onChange={onChange} onOpenColorPanel={onOpenColorPanel} />
        </span>
      </div>

      {(tweak.type === "int" || tweak.type === "float") && tweak.min !== undefined && tweak.max !== undefined ? (
        <input
          className="tweaks-range"
          type="range"
          aria-label={tweak.name}
          min={tweak.min}
          max={tweak.max}
          step={tweak.step ?? (tweak.type === "int" ? 1 : 0.01)}
          value={Number(tweak.value)}
          onChange={(event) => onChange(tweak, Number(event.currentTarget.value))}
        />
      ) : null}

      {tweak.type === "string" ? (
        <input
          className="tweaks-string"
          type="text"
          aria-label={tweak.name}
          value={String(tweak.value)}
          onChange={(event) => onChange(tweak, event.currentTarget.value)}
        />
      ) : null}
    </div>
  );
}

export function TweakActionControl({
  action,
  invoking = false,
  onInvoke
}: {
  action: TweakActionDescriptor;
  invoking?: boolean;
  onInvoke(action: TweakActionDescriptor): void;
}): JSX.Element {
  return (
    <div className="tweaks-control">
      <div className="tweaks-control-line">
        <span className="tweaks-control-label">{tweakLabel(action.name)}</span>
        <span className="tweaks-control-field">
          <button
            className="tweaks-action-button"
            type="button"
            aria-label={`${action.conflicted ? "Conflict" : "Run"} ${action.name}`}
            disabled={Boolean(action.conflicted) || invoking}
            onClick={() => onInvoke(action)}
          >
            {action.conflicted ? "Conflict" : "Run"}
          </button>
        </span>
      </div>
      {action.conflicted ? (
        <p className="tweaks-action-conflict" role="alert">
          Conflicting registrations. Use a unique action name.
        </p>
      ) : null}
    </div>
  );
}

export function TweakField({
  tweak,
  onChange,
  onOpenColorPanel
}: {
  tweak: TweakValueDescriptor;
  onChange(tweak: TweakValueDescriptor, value: TweakValue): void;
  onOpenColorPanel?(tweak: TweakValueDescriptor): void;
}): JSX.Element | null {
  if (tweak.type === "boolean") {
    return (
      <input
        className="tweaks-checkbox"
        type="checkbox"
        aria-label={tweak.name}
        checked={Boolean(tweak.value)}
        onChange={(event) => onChange(tweak, event.currentTarget.checked)}
      />
    );
  }

  if (tweak.type === "color") {
    return <TweakColorField tweak={tweak} onChange={onChange} onOpenColorPanel={onOpenColorPanel} />;
  }

  if (tweak.type === "enum") {
    return <TweakEnumField tweak={tweak} onChange={onChange} />;
  }

  if (tweak.type === "int" || tweak.type === "float") {
    return (
      <input
        className="tweaks-number"
        type="number"
        aria-label={`${tweak.name} value`}
        min={tweak.min}
        max={tweak.max}
        step={tweak.step ?? (tweak.type === "int" ? 1 : 0.01)}
        value={Number(tweak.value)}
        onChange={(event) => {
          const value = Number(event.currentTarget.value);
          if (event.currentTarget.validity.valid && Number.isFinite(value)) {
            onChange(tweak, value);
          }
        }}
      />
    );
  }

  return null;
}

function TweakEnumField({
  tweak,
  onChange
}: {
  tweak: TweakValueDescriptor;
  onChange(tweak: TweakValueDescriptor, value: TweakValue): void;
}): JSX.Element {
  const [listboxStyle, setListboxStyle] = useState<CSSProperties | null>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const listboxId = useId();
  const options = tweak.options ?? [];
  const expanded = listboxStyle !== null;
  const close = useCallback(() => {
    setListboxStyle(null);
    triggerRef.current?.focus();
  }, []);

  useEffect(() => {
    if (!expanded) return;

    const dismissOutside = (event: Event) => {
      if (event.target instanceof Node && rootRef.current?.contains(event.target)) return;
      setListboxStyle(null);
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key !== "Escape") return;
      event.preventDefault();
      close();
    };

    const controller = new AbortController();
    const { signal } = controller;
    window.addEventListener("pointerdown", dismissOutside, { signal });
    window.addEventListener("keydown", closeOnEscape, { signal });
    window.addEventListener("scroll", dismissOutside, { capture: true, signal });
    window.addEventListener("resize", dismissOutside, { signal });
    return () => controller.abort();
  }, [close, expanded]);

  const open = () => {
    const bounds = triggerRef.current?.getBoundingClientRect();
    if (!bounds) return;

    const availableBelow = window.innerHeight - bounds.bottom;
    const openAbove = availableBelow < Math.min(options.length * 30 + 8, 240) && bounds.top > availableBelow;
    setListboxStyle({
      ...(openAbove ? { bottom: window.innerHeight - bounds.top + 4 } : { top: bounds.bottom + 4 }),
      right: Math.max(8, window.innerWidth - bounds.right),
      minWidth: bounds.width,
      maxHeight: Math.max(80, (openAbove ? bounds.top : availableBelow) - 12)
    });
  };

  const navigate = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (!["ArrowDown", "ArrowUp", "Home", "End"].includes(event.key) || options.length === 0) return;

    event.preventDefault();
    const selected = options.indexOf(String(tweak.value));
    const focused = Number((event.target as HTMLElement).dataset.optionIndex ?? selected);
    const current = focused < 0 ? 0 : focused;
    const index =
      event.key === "Home"
        ? 0
        : event.key === "End"
          ? options.length - 1
          : Math.max(0, Math.min(options.length - 1, current + (expanded ? (event.key === "ArrowDown" ? 1 : -1) : 0)));

    if (!expanded) open();
    requestAnimationFrame(() => {
      rootRef.current?.querySelector<HTMLButtonElement>(`[data-option-index="${index}"]`)?.focus();
    });
  };

  return (
    <div
      className="tweaks-select-wrap"
      ref={rootRef}
      onKeyDown={navigate}
      onBlur={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget)) setListboxStyle(null);
      }}
    >
      <button
        className="tweaks-select"
        type="button"
        aria-label={`${tweak.name}: ${String(tweak.value)}`}
        aria-haspopup="listbox"
        aria-expanded={expanded}
        aria-controls={expanded ? listboxId : undefined}
        ref={triggerRef}
        onClick={() => (expanded ? setListboxStyle(null) : open())}
      >
        <span>{String(tweak.value)}</span>
        <ChevronDown size={12} aria-hidden="true" />
      </button>
      {expanded ? (
        <TweakEnumListbox id={listboxId} style={listboxStyle} tweak={tweak} onChange={onChange} onClose={close} />
      ) : null}
    </div>
  );
}

export function TweakEnumListbox({
  id,
  style,
  tweak,
  onChange,
  onClose
}: {
  id: string;
  style?: CSSProperties;
  tweak: TweakValueDescriptor;
  onChange(tweak: TweakValueDescriptor, value: TweakValue): void;
  onClose(): void;
}): JSX.Element {
  const select = (value: string) => {
    if (value !== String(tweak.value)) onChange(tweak, value);
    onClose();
  };

  return (
    <div className="tweaks-select-listbox" id={id} role="listbox" aria-label={tweak.name} style={style}>
      {(tweak.options ?? []).map((option, index) => (
        <button
          className="tweaks-select-option"
          key={option}
          type="button"
          role="option"
          aria-selected={option === String(tweak.value)}
          data-option-index={index}
          tabIndex={option === String(tweak.value) ? 0 : -1}
          onPointerDown={(event) => {
            if (event.button !== 0) return;
            event.preventDefault();
            select(option);
          }}
          onClick={(event) => {
            if (event.detail === 0) select(option);
          }}
        >
          {option}
        </button>
      ))}
    </div>
  );
}

export function TweakColorField({
  tweak,
  onChange,
  onOpenColorPanel
}: {
  tweak: TweakValueDescriptor;
  onChange(tweak: TweakValueDescriptor, value: TweakValue): void;
  onOpenColorPanel?(tweak: TweakValueDescriptor): void;
}): JSX.Element {
  const committed = String(tweak.value);
  const [draft, setDraft] = useState(() => ({ committed, value: committed }));
  const value = draft.committed === committed ? draft.value : committed;

  return (
    <span className="tweaks-color-fields">
      {onOpenColorPanel ? (
        <button
          className="tweaks-color tweaks-color-button"
          type="button"
          aria-label={`${tweak.name} color`}
          onClick={() => onOpenColorPanel(tweak)}
        >
          <span className="tweaks-color-swatch" style={{ backgroundColor: committed }} />
        </button>
      ) : (
        <input
          className="tweaks-color"
          type="color"
          aria-label={`${tweak.name} color`}
          value={committed.slice(0, 7)}
          onChange={(event) => {
            onChange(tweak, tweakColorWithPreservedAlpha(committed, event.currentTarget.value));
          }}
        />
      )}
      <input
        className="tweaks-hex"
        type="text"
        aria-label={`${tweak.name} hex`}
        maxLength={9}
        value={value}
        onChange={(event) => {
          const next = event.currentTarget.value;
          setDraft({ committed, value: next });

          const color = parseTweakColor(next);
          if (color !== null) onChange(tweak, color);
        }}
        onBlur={() => {
          if (parseTweakColor(value) === null) setDraft({ committed, value: committed });
        }}
      />
    </span>
  );
}

export function parseTweakColor(value: string): string | null {
  return /^#[\da-f]{6}(?:[\da-f]{2})?$/i.test(value) ? value.toUpperCase() : null;
}

export function tweakColorWithPreservedAlpha(committed: string, color: string): string {
  const alpha = committed.length === 9 ? committed.slice(7) : "";
  return `${color.toUpperCase()}${alpha}`;
}

export function nativePanelTweakColor(event: NativeColorPanelChange, sessionId: string): string | null {
  if (event.sessionId !== sessionId) return null;

  const normalized = parseTweakColor(event.color);
  if (normalized === null || normalized.length !== 9) return null;

  return normalized.slice(7) === "FF" ? normalized.slice(0, 7) : normalized;
}
