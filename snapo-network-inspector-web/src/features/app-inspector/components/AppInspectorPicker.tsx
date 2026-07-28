import { Check, ChevronDown, Network, SlidersHorizontal } from "lucide-react";
import { useEffect, useId, useRef, useState } from "react";
import type { AppInspectorOption, InspectableApp, SelectedAppInspector } from "../../../network/bridge-types";

export function AppInspectorPicker({
  apps,
  selection,
  onSelect
}: {
  apps: InspectableApp[];
  selection: SelectedAppInspector | null;
  onSelect(app: InspectableApp, option: AppInspectorOption): void;
}): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const menuId = useId();
  const selectedApp = apps.find((app) => app.id === selection?.appId);

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
    <div className="inspector-app-select" ref={rootRef}>
      <button
        className="inspector-app-picker-button"
        type="button"
        aria-label="Select an app and inspector"
        aria-haspopup="menu"
        aria-expanded={expanded}
        aria-controls={menuId}
        disabled={apps.length === 0}
        onClick={() => setExpanded((value) => !value)}
      >
        <AppIcon app={selectedApp} size={28} />
        <span className="inspector-app-picker-text">
          <span className="inspector-app-picker-name">
            {selectedApp == null
              ? "No Apps Found"
              : `${selectedApp.name} · ${selection?.kind === "tweaks" ? "Tweaks" : "Network"}`}
          </span>
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
  onSelect(app: InspectableApp, option: AppInspectorOption): void;
}): JSX.Element {
  return (
    <div className="inspector-app-menu" id={id} role="menu" aria-label="Apps and inspectors">
      {apps.map((app) => (
        <div className="inspector-app-group" key={app.id}>
          <div className="inspector-app-heading" title={app.packageName}>
            <AppIcon app={app} size={16} />
            <span className="inspector-app-heading-name">{app.name}</span>
            <span className="inspector-app-heading-device">{app.deviceDisplayTitle}</span>
          </div>

          {app.inspectors.map((option) => {
            const selected =
              selection?.appId === app.id &&
              selection.kind === option.kind &&
              selection.server.deviceId === option.server.deviceId &&
              selection.server.socketName === option.server.socketName;
            const Icon = option.kind === "network" ? Network : SlidersHorizontal;
            const title = option.kind === "network" ? "Network" : "Tweaks";

            return (
              <button
                className="inspector-app-option"
                data-selected={selected}
                key={`${option.kind}:${option.server.socketName}`}
                type="button"
                role="menuitemradio"
                aria-checked={selected}
                aria-label={`${app.name}, ${title}, ${app.deviceDisplayTitle}`}
                onClick={() => onSelect(app, option)}
              >
                <Icon size={16} aria-hidden="true" />
                <span>{title}</span>
                <Check className="inspector-app-option-check" size={15} aria-hidden="true" />
              </button>
            );
          })}
        </div>
      ))}
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
