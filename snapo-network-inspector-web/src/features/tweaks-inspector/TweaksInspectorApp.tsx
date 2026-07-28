import { RotateCcw } from "lucide-react";
import { useCallback, useEffect, useMemo, useState } from "react";
import type {
  AppInspectorOption,
  InspectableApp,
  SelectedAppInspector,
  TweakDescriptor,
  TweakValue
} from "../../network/bridge-types";
import type { NetworkClient } from "../../network/client";
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

export function TweaksInspectorApp({
  client,
  apps,
  selection,
  onSelect
}: {
  client: NetworkClient;
  apps: InspectableApp[];
  selection: SelectedAppInspector;
  onSelect(app: InspectableApp, option: AppInspectorOption): void;
}): JSX.Element {
  const [tweaks, setTweaks] = useState<TweakDescriptor[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [orderByApp] = useState(() => new Map<string, TweakOrdering>());
  const server = selection.server;
  const queue = useMemo(
    () =>
      new TweakUpdateQueue(client, server, {
        onUpdate(updates, pending) {
          setTweaks((current) =>
            current.map((tweak) => {
              const update = updates.find((candidate) => candidate.name === tweak.name);
              return update && !pending.has(tweak.name) ? { ...tweak, value: update.value } : tweak;
            })
          );
        },
        onError: setError,
        onSavingChange: setSaving
      }),
    [client, server]
  );

  useEffect(() => {
    let disposed = false;
    let streamId: string | undefined;

    const unsubscribe = client.onTweaksChanged((event) => {
      if (
        disposed ||
        event.server.deviceId !== server.deviceId ||
        event.server.socketName !== server.socketName ||
        (streamId !== undefined && event.streamId !== streamId)
      ) {
        return;
      }

      setTweaks((current) => reconcileStreamedTweaks(current, event.tweaks, queue.pending, queue.inFlight));
      setError(null);
    });

    void client
      .listTweaks(server)
      .then((response) => {
        if (disposed) return;
        setTweaks((current) => reconcileStreamedTweaks(current, response.tweaks, queue.pending, queue.inFlight));
        setError(null);
      })
      .catch((cause: unknown) => {
        if (disposed) return;
        setError(cause instanceof Error ? cause.message : "Unable to load tweaks.");
      });

    void client
      .startTweakStream(server)
      .then((started) => {
        if (disposed) {
          void client.stopTweakStream(started.streamId);
          return;
        }
        streamId = started.streamId;
      })
      .catch((cause: unknown) => {
        if (disposed) return;
        setError(cause instanceof Error ? cause.message : "Unable to stream tweaks.");
      });

    return () => {
      disposed = true;
      queue.cancel();
      unsubscribe();
      if (streamId !== undefined) void client.stopTweakStream(streamId);
    };
  }, [client, queue, server]);

  const updateTweak = useCallback(
    (tweak: TweakDescriptor, value: TweakValue) => {
      setTweaks((current) => current.map((item) => (item.name === tweak.name ? { ...item, value } : item)));
      queue.enqueue(tweak.name, value);
      void queue.flush();
    },
    [queue]
  );

  const resetAll = useCallback(() => {
    for (const tweak of tweaks) {
      queue.enqueue(tweak.name, tweak.default);
    }
    setTweaks((current) => current.map((tweak) => ({ ...tweak, value: tweak.default })));
    void queue.flush();
  }, [queue, tweaks]);

  useEffect(() => client.onNativeTweaksReset(resetAll), [client, resetAll]);

  const sections = useMemo(
    () => groupTweaks(tweaks, selection.appId, orderByApp),
    [orderByApp, selection.appId, tweaks]
  );
  const hasChanges = canResetTweaks(tweaks);

  useEffect(() => {
    client.nativeTweaksStateChanged({
      server,
      hasResettableTweaks: hasChanges && !saving
    });
  }, [client, hasChanges, saving, server]);

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
              disabled={!hasChanges || saving}
              onClick={resetAll}
            >
              <RotateCcw size={16} aria-hidden="true" />
            </button>
          </div>
          <AppInspectorPicker apps={apps} selection={selection} onSelect={onSelect} />
        </header>
      ) : null}

      <div className="tweaks-inspector-content">
        {error ? (
          <p className="tweaks-error" role="alert">
            {error}
          </p>
        ) : null}
        <div className="tweaks-columns">
          {sections.map((column, index) => (
            <div className="tweaks-column" key={index}>
              {column.map((section) => (
                <section className="tweaks-section" key={section.name}>
                  {section.name ? <h2>{section.name}</h2> : null}
                  <div className="tweaks-section-list">
                    {section.tweaks.map((tweak) => (
                      <TweakControl key={tweak.name} tweak={tweak} onChange={updateTweak} />
                    ))}
                  </div>
                </section>
              ))}
            </div>
          ))}
        </div>
      </div>
    </main>
  );
}

export function canResetTweaks(tweaks: TweakDescriptor[]): boolean {
  return tweaks.some((tweak) => tweak.value !== tweak.default);
}

export function reconcileStreamedTweaks(
  current: TweakDescriptor[],
  incoming: TweakDescriptor[],
  pending: ReadonlyMap<string, TweakValue>,
  inFlight: ReadonlySet<string>
): TweakDescriptor[] {
  const currentByName = new Map(current.map((tweak) => [tweak.name, tweak]));

  return incoming.map((tweak) => {
    const existing = currentByName.get(tweak.name);
    if (existing && (pending.has(tweak.name) || inFlight.has(tweak.name))) {
      return { ...tweak, value: existing.value };
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
  onChange
}: {
  tweak: TweakDescriptor;
  onChange(tweak: TweakDescriptor, value: TweakValue): void;
}): JSX.Element {
  const label = tweakLabel(tweak.name);
  const changed = tweak.value !== tweak.default;

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
            onClick={() => onChange(tweak, tweak.default)}
          >
            <RotateCcw size={13} aria-hidden="true" />
          </button>
        ) : null}
        <span className="tweaks-control-field">
          <TweakField tweak={tweak} onChange={onChange} />
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

function TweakField({
  tweak,
  onChange
}: {
  tweak: TweakDescriptor;
  onChange(tweak: TweakDescriptor, value: TweakValue): void;
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
    return <TweakColorField tweak={tweak} onChange={onChange} />;
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

function TweakColorField({
  tweak,
  onChange
}: {
  tweak: TweakDescriptor;
  onChange(tweak: TweakDescriptor, value: TweakValue): void;
}): JSX.Element {
  const committed = String(tweak.value);
  const [draft, setDraft] = useState(() => ({ committed, value: committed }));
  const value = draft.committed === committed ? draft.value : committed;

  return (
    <span className="tweaks-color-fields">
      <input
        className="tweaks-color"
        type="color"
        aria-label={`${tweak.name} color`}
        value={committed.slice(0, 7)}
        onChange={(event) => {
          const alpha = committed.length === 9 ? committed.slice(7) : "";
          onChange(tweak, `${event.currentTarget.value.toUpperCase()}${alpha}`);
        }}
      />
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
