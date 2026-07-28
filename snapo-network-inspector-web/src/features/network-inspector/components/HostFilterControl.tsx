import { Filter, X } from "lucide-react";
import { useEffect, useId, useRef, useState } from "react";

export function HostFilterControl({
  hiddenHosts,
  onRemoveHost
}: {
  hiddenHosts: string[];
  onRemoveHost(host: string): void;
}): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const popupId = useId();
  const rootRef = useRef<HTMLDivElement>(null);

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

  const buttonLabel =
    hiddenHosts.length === 0
      ? "Manage hidden hosts"
      : `Manage hidden hosts (${hiddenHosts.length} active ${hiddenHosts.length === 1 ? "filter" : "filters"})`;

  return (
    <div className="host-filter-control" ref={rootRef}>
      <button
        className={hiddenHosts.length === 0 ? "toolbar-icon-button" : "toolbar-icon-button host-filter-active"}
        type="button"
        title={buttonLabel}
        aria-label={buttonLabel}
        aria-haspopup="dialog"
        aria-expanded={expanded}
        aria-controls={popupId}
        onClick={() => setExpanded((value) => !value)}
      >
        <Filter size={16} aria-hidden="true" />
        {hiddenHosts.length === 0 ? null : (
          <span className="host-filter-count" aria-hidden="true">
            {hiddenHosts.length > 99 ? "99+" : hiddenHosts.length}
          </span>
        )}
      </button>

      {expanded ? <HostFilterPopover popupId={popupId} hiddenHosts={hiddenHosts} onRemoveHost={onRemoveHost} /> : null}
    </div>
  );
}

export function HostFilterPopover({
  popupId,
  hiddenHosts,
  onRemoveHost
}: {
  popupId: string;
  hiddenHosts: string[];
  onRemoveHost(host: string): void;
}): JSX.Element {
  return (
    <div className="host-filter-popup" id={popupId} role="dialog" aria-labelledby={`${popupId}-title`}>
      <div className="host-filter-heading" id={`${popupId}-title`}>
        Hidden hosts
      </div>
      <p className="host-filter-description">Right-click on any request and click &quot;Add to filtered hosts&quot;.</p>

      {hiddenHosts.length === 0 ? (
        <p className="host-filter-empty">No hidden hosts</p>
      ) : (
        <ul className="host-filter-list">
          {hiddenHosts.map((host) => (
            <li className="host-filter-item" key={host}>
              <span className="host-filter-hostname">{host}</span>
              <button
                className="toolbar-icon-button host-filter-remove"
                type="button"
                aria-label={`Show ${host} again`}
                title={`Show ${host} again`}
                onClick={() => onRemoveHost(host)}
              >
                <X size={14} aria-hidden="true" />
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
