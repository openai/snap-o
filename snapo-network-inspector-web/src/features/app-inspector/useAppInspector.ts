import { useEffect, useState } from "preact/hooks";
import type { InspectorHostState, SelectedAppInspector } from "../../network/bridge-types";
import type { InspectorHostClient } from "../../host/client";

export interface AppLaunchControl {
  pending: boolean;
  error: string | null;
  open(): void;
}

const emptyState: InspectorHostState = {
  revision: -1,
  selection: null,
  selectedApp: null,
  networkServer: null,
  preferredKind: "network",
  isConnected: false,
  isWaiting: true
};

function retainSelection(previous: SelectedAppInspector | null, next: SelectedAppInspector | null) {
  return previous?.appId === next?.appId &&
    previous?.kind === next?.kind &&
    previous?.server.deviceId === next?.server.deviceId &&
    previous?.server.socketName === next?.server.socketName &&
    previous?.protocolVersion === next?.protocolVersion
    ? previous
    : next;
}

export function useAppInspector(client: InspectorHostClient) {
  const [host, setHost] = useState<InspectorHostState>(emptyState);
  useEffect(() => {
    let disposed = false;
    const receive = (next: InspectorHostState) => {
      if (disposed) return;
      setHost((previous) => {
        if (next.revision < previous.revision) return previous;
        // Swift omits absent optional fields. Keep stable connection objects across scans.
        const state = { ...emptyState, ...next };
        state.selection = retainSelection(previous.selection, state.selection);
        return state;
      });
    };
    const unsubscribe = client.onInspectorHostState(receive);
    void client.inspectorHostState().then(receive, () => {});
    return () => {
      disposed = true;
      unsubscribe();
    };
  }, [client]);

  const appLaunch: AppLaunchControl | null =
    host.appLaunch && host.selectedApp
      ? {
          pending: host.appLaunch.pending,
          error: host.appLaunch.error ?? null,
          open: () => {
            void client.openSelectedApp(host.selectedApp!.id).catch(() => {});
          }
        }
      : null;
  return { ...host, appLaunch };
}
