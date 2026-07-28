import { useCallback, useEffect, useMemo, useState } from "react";
import type { AppInspectorOption, InspectableApp, SelectedAppInspector } from "./network/bridge-types";
import { createNetworkClient } from "./network/client";
import { NetworkInspectorApp } from "./features/network-inspector/NetworkInspectorApp";
import { TweaksInspectorApp } from "./features/tweaks-inspector/TweaksInspectorApp";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  const [apps, setApps] = useState<InspectableApp[]>([]);
  const [selection, setSelection] = useState<SelectedAppInspector | null>(null);

  const selectInspector = useCallback((app: InspectableApp, option: AppInspectorOption) => {
    setSelection({ appId: app.id, kind: option.kind, server: option.server });
  }, []);

  useEffect(() => {
    let disposed = false;

    const refresh = async () => {
      try {
        const discovered = await client.listInspectorApps();
        if (disposed) return;

        setApps(discovered);
        setSelection((current) => {
          if (
            current &&
            discovered.some(
              (app) =>
                app.id === current.appId &&
                app.inspectors.some(
                  (option) =>
                    option.kind === current.kind &&
                    option.server.deviceId === current.server.deviceId &&
                    option.server.socketName === current.server.socketName
                )
            )
          ) {
            return current;
          }

          const app = discovered[0];
          const option = app?.inspectors[0];
          return app && option ? { appId: app.id, kind: option.kind, server: option.server } : null;
        });
      } catch {
        if (!disposed) setApps([]);
      }
    };

    void refresh();
    const interval = window.setInterval(() => {
      if (!document.hidden) void refresh();
    }, 2_500);
    const unsubscribe = client.onNativeSelectedInspector(setSelection);

    return () => {
      disposed = true;
      window.clearInterval(interval);
      unsubscribe();
    };
  }, [client]);

  return (
    <div className="window-frame">
      {selection?.kind === "tweaks" ? (
        <TweaksInspectorApp client={client} apps={apps} selection={selection} onSelect={selectInspector} />
      ) : (
        <NetworkInspectorApp inspectorApps={apps} inspectorSelection={selection} onInspectorSelect={selectInspector} />
      )}
    </div>
  );
}
