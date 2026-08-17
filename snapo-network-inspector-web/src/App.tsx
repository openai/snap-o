import { useCallback, useEffect, useMemo, useState } from "react";
import type { AppInspectorOption, InspectableApp, SelectedAppInspector } from "./network/bridge-types";
import { createNetworkClient } from "./network/client";
import { NetworkInspectorApp } from "./features/network-inspector/NetworkInspectorApp";
import { TweaksInspectorApp } from "./features/tweaks-inspector/TweaksInspectorApp";
import { isInspectorMetadataPending, reconcileInspectorSelection } from "./features/app-inspector/selection";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  const [apps, setApps] = useState<InspectableApp[]>([]);
  const [selection, setSelection] = useState<SelectedAppInspector | null>(null);

  const selectInspector = useCallback((app: InspectableApp, option: AppInspectorOption) => {
    setSelection({ appId: app.id, kind: option.kind, server: option.server, protocolVersion: option.protocolVersion });
  }, []);

  useEffect(() => {
    let disposed = false;

    const refresh = async () => {
      try {
        const discovered = await client.listInspectorApps();
        if (disposed) return;

        setApps(discovered);
        setSelection((current) => reconcileInspectorSelection(discovered, current));
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
      {selection && isInspectorMetadataPending(selection, client.usesNativeServerPicker) ? (
        <main className="tweaks-inspector">
          <div className="tweaks-inspector-content" role="status">
            Loading inspector…
          </div>
        </main>
      ) : selection?.kind === "tweaks" ? (
        <TweaksInspectorApp client={client} apps={apps} selection={selection} onSelect={selectInspector} />
      ) : (
        <NetworkInspectorApp inspectorApps={apps} inspectorSelection={selection} onInspectorSelect={selectInspector} />
      )}
    </div>
  );
}
