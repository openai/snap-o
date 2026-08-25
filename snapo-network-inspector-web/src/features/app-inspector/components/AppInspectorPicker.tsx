import { Check, ChevronDown, Network, SlidersHorizontal } from "lucide-react";
import { useEffect, useId, useRef, useState } from "react";
import type {
  AppInspectorKind,
  AppInspectorOption,
  InspectableApp,
  SelectedAppInspector
} from "../../../network/bridge-types";

export function AppInspectorPicker({
  apps,
  selection,
  selectedApp: rememberedApp,
  preferredKind,
  onSelect
}: {
  apps: InspectableApp[];
  selection: SelectedAppInspector | null;
  selectedApp?: InspectableApp | null;
  preferredKind?: AppInspectorKind | null;
  onSelect(app: InspectableApp, option?: AppInspectorOption): void;
}): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const menuId = useId();
  const selectedApp = rememberedApp ?? apps.find((app) => app.id === selection?.appId);

  useEffect(() => {
    if (!expanded) return;

    const closeOnOutsidePointer = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setExpanded(false);
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setExpanded(false);
    };

    window.addEventListener("pointerdown", closeOnOutsidePointer);
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      window.removeEventListener("pointerdown", closeOnOutsidePointer);
      window.removeEventListener("keydown", closeOnEscape);
    };
  }, [expanded]);

  return (
    <div className="inspector-app-toolbar">
      <div className="inspector-app-select" ref={rootRef}>
        <button
          className="inspector-app-picker-button"
          type="button"
          aria-label="Select an app"
          aria-haspopup="menu"
          aria-expanded={expanded}
          aria-controls={menuId}
          disabled={apps.length === 0}
          onClick={() => setExpanded((value) => !value)}
        >
          <AppIcon app={selectedApp} size={28} />
          <span className="inspector-app-picker-text">
            <span className="inspector-app-picker-name">{selectedApp?.name ?? "No Apps Found"}</span>
            <span className="inspector-app-picker-device">
              {selectedApp?.deviceDisplayTitle ?? "No devices detected"}
            </span>
          </span>
          <ChevronDown size={16} aria-hidden="true" />
        </button>

        {expanded ? (
          <AppInspectorMenu
            id={menuId}
            apps={apps}
            selection={selection}
            onSelect={(app, option) => {
              onSelect(app, option);
              setExpanded(false);
            }}
          />
        ) : null}
      </div>

      {selectedApp ? (
        <AppInspectorViewPicker
          app={selectedApp}
          selection={selection}
          preferredKind={preferredKind}
          onSelect={onSelect}
        />
      ) : null}
    </div>
  );
}

export function AppInspectorViewPicker({
  app,
  selection,
  preferredKind,
  onSelect
}: {
  app: InspectableApp;
  selection: SelectedAppInspector | null;
  preferredKind?: AppInspectorKind | null;
  onSelect(app: InspectableApp, option?: AppInspectorOption): void;
}): JSX.Element | null {
  if (app.inspectors.length === 0 || (app.inspectors.length < 2 && selection != null)) return null;

  return (
    <div className="inspector-app-segments" role="radiogroup" aria-label="Inspector">
      {app.inspectors.map((option) => {
        const selected = (preferredKind ?? (selection?.appId === app.id ? selection.kind : null)) === option.kind;
        const title = option.kind === "network" ? "Network" : "Tweaks";
        const Icon = option.kind === "network" ? Network : SlidersHorizontal;

        return (
          <button
            className="inspector-app-segment"
            key={option.kind}
            type="button"
            role="radio"
            aria-label={title}
            aria-checked={selected}
            title={title}
            onClick={() => onSelect(app, option)}
          >
            <Icon size={16} aria-hidden="true" />
          </button>
        );
      })}
    </div>
  );
}

export function AppInspectorMenu({
  id,
  apps,
  selection,
  onSelect
}: {
  id?: string;
  apps: InspectableApp[];
  selection: SelectedAppInspector | null;
  onSelect(app: InspectableApp, option?: AppInspectorOption): void;
}): JSX.Element {
  return (
    <div className="inspector-app-menu" id={id} role="menu" aria-label="Apps">
      {apps.map((app) => {
        const option = app.inspectors[0];
        const selected = selection?.appId === app.id;

        return (
          <div className="inspector-app-row" data-selected={selected} key={app.id} role="presentation">
            <button
              className="inspector-app-option"
              style={{ paddingRight: 16 + app.inspectors.length * 28 }}
              type="button"
              role="menuitemradio"
              aria-checked={selected}
              aria-label={`${app.name}, ${app.deviceDisplayTitle}`}
              title={app.packageName ?? app.processName ?? app.name}
              disabled={!option}
              onClick={() => {
                if (option) onSelect(app);
              }}
            >
              <Check className="inspector-app-option-check" size={15} aria-hidden="true" />
              <AppIcon app={app} size={28} />
              <span className="inspector-app-picker-text">
                <span className="inspector-app-picker-name">{app.name}</span>
                <span className="inspector-app-picker-device">{app.deviceDisplayTitle}</span>
              </span>
            </button>
            <div className="inspector-app-shortcuts" role="presentation">
              {app.inspectors.map((inspector) => {
                const title = inspector.kind === "network" ? "Network" : "Tweaks";
                const Icon = inspector.kind === "network" ? Network : SlidersHorizontal;

                return (
                  <button
                    className="inspector-app-shortcut"
                    key={`${inspector.kind}:${inspector.server.socketName}`}
                    type="button"
                    role="menuitem"
                    aria-label={`Open ${title} for ${app.name}, ${app.deviceDisplayTitle}`}
                    title={`Open ${title}`}
                    onClick={() => onSelect(app, inspector)}
                  >
                    <Icon size={15} aria-hidden="true" />
                  </button>
                );
              })}
            </div>
          </div>
        );
      })}
    </div>
  );
}

function AppIcon({ app, size }: { app?: InspectableApp; size: number }): JSX.Element {
  return (
    <span className="inspector-app-icon" style={{ width: size, height: size }}>
      {app?.appIconBase64 ? <img src={`data:image/png;base64,${app.appIconBase64}`} alt="" /> : null}
    </span>
  );
}
