import { ChevronDown } from "lucide-react";
import { useEffect, useId, useRef, useState } from "react";
import type { SnapOServer } from "../../../network/bridge-types";
import type { ServerId } from "../../../network/cdp";

export function ServerSelect({
  servers,
  selectedServer,
  onChange
}: {
  servers: SnapOServer[];
  selectedServer: SnapOServer | null;
  onChange: (server: ServerId | null) => void;
}): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const menuId = useId();
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

  if (servers.length === 0) return <div className="no-servers-banner">No Apps Found</div>;

  return (
    <div className="server-select" ref={rootRef}>
      <button
        className="server-picker-button"
        type="button"
        aria-haspopup="menu"
        aria-expanded={expanded}
        aria-controls={menuId}
        onClick={() => setExpanded((value) => !value)}
      >
        <ServerAppIcon server={selectedServer} />
        <span className="server-picker-text">
          <span className="server-name">{selectedServer?.displayName ?? "Select an App"}</span>
          {selectedServer?.deviceDisplayTitle == null || selectedServer.deviceDisplayTitle.length === 0 ? null : (
            <span className="server-device">{selectedServer.deviceDisplayTitle}</span>
          )}
        </span>
        <ChevronDown size={18} className={expanded ? "server-chevron expanded" : "server-chevron"} />
      </button>

      {expanded ? (
        <div className="server-picker-menu" id={menuId} role="menu" aria-label="Detected servers">
          <div className="server-picker-menu-header">Detected servers</div>
          {servers.map((server) => (
            <button
              className="server-picker-menu-item"
              type="button"
              role="menuitem"
              key={`${server.deviceId}:${server.socketName}`}
              onClick={() => {
                onChange({ deviceId: server.deviceId, socketName: server.socketName });
                setExpanded(false);
              }}
            >
              <ServerAppIcon server={server} />
              <span className="server-picker-menu-text">
                <span className="server-picker-menu-name">{server.displayName}</span>
                <span className="server-picker-menu-device">{server.deviceDisplayTitle}</span>
              </span>
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

function ServerAppIcon({ server }: { server: SnapOServer | null }): JSX.Element {
  const image = server?.appIconBase64;
  const [failedImage, setFailedImage] = useState<string | null>(null);

  const hasImage = image != null && image.length > 0 && failedImage !== image;
  return (
    <span className={hasImage ? "server-app-icon" : "server-app-icon placeholder"}>
      {hasImage ? <img src={`data:image/png;base64,${image}`} alt="" onError={() => setFailedImage(image)} /> : null}
      {server == null ? null : (
        <span className={`server-status-dot ${server.isConnected ? "connected" : "disconnected"}`} />
      )}
    </span>
  );
}
