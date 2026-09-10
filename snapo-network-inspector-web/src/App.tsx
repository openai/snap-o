import type { JSX } from "preact";
import { useMemo } from "preact/hooks";
import { createNetworkClient } from "./network/client";
import { NetworkInspectorApp } from "./features/network-inspector/NetworkInspectorApp";
import { useNetworkInspectorModel } from "./features/network-inspector/hooks/useNetworkInspectorModel";
import { InspectorWaitingState } from "./features/app-inspector/components/InspectorWaitingState";
import { useAppInspector } from "./features/app-inspector/useAppInspector";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  const { selection, selectedApp, networkServer, isActive, isWaiting, appLaunch } = useAppInspector(client);
  const networkModel = useNetworkInspectorModel(client, networkServer, isActive);

  return (
    <div className="window-frame">
      {isWaiting && !selection ? (
        <main className="inspector-loading-shell">
          <InspectorWaitingState launch={appLaunch} app={selectedApp} />
        </main>
      ) : (
        <NetworkInspectorApp model={networkModel} selectedApp={selectedApp} appLaunch={appLaunch} />
      )}
    </div>
  );
}
