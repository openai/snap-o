import { ChevronDown } from "lucide-react";
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
  if (servers.length === 0) return <div className="no-servers-banner">No Apps Found</div>;

  const value = selectedServer == null ? "" : serverOptionValue(selectedServer);
  return (
    <div className="server-select">
      <div className="server-picker-button" aria-hidden="true">
        <ServerAppIcon server={selectedServer} />
        <span className="server-picker-text">
          <span className="server-name">{selectedServer?.displayName ?? "Select an App"}</span>
          {selectedServer?.deviceDisplayTitle == null || selectedServer.deviceDisplayTitle.length === 0 ? null : (
            <span className="server-device">{selectedServer.deviceDisplayTitle}</span>
          )}
        </span>
        <ChevronDown size={18} className="server-chevron" />
      </div>
      <select
        className="server-picker-select"
        aria-label="Select an App"
        value={value}
        onChange={(event) => {
          const selected = servers.find((server) => serverOptionValue(server) === event.target.value);
          onChange(selected == null ? null : { deviceId: selected.deviceId, socketName: selected.socketName });
        }}
      >
        {selectedServer == null ? <option value="">Select an App</option> : null}
        {servers.map((server) => (
          <option key={`${server.deviceId}:${server.socketName}`} value={serverOptionValue(server)}>
            {server.displayName} · {server.deviceDisplayTitle}
          </option>
        ))}
      </select>
    </div>
  );
}

function ServerAppIcon({ server }: { server: SnapOServer | null }): JSX.Element {
  const image = server?.appIconBase64;
  return (
    <span className="server-app-icon">
      {image == null || image.length === 0 ? null : <img src={`data:image/png;base64,${image}`} alt="" />}
      {server == null ? null : <span className={`server-status-dot ${server.isConnected ? "connected" : "disconnected"}`} />}
    </span>
  );
}

function serverOptionValue(server: SnapOServer): string {
  return `${server.deviceId}\u0000${server.socketName}`;
}
