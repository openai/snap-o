import type { JSX } from "preact";
import { useMemo } from "preact/hooks";
import { createNetworkClient } from "./network/client";
import { NetworkInspectorApp } from "./features/network-inspector/NetworkInspectorApp";
import { useNetworkInspectorModel } from "./features/network-inspector/hooks/useNetworkInspectorModel";
import { TweaksInspectorApp } from "./features/tweaks-inspector/TweaksInspectorApp";
import { InspectorWaitingState } from "./features/app-inspector/components/InspectorWaitingState";
import { useAppInspector } from "./features/app-inspector/useAppInspector";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  const { selection, selectedApp, networkServer, preferredKind, isConnected, isWaiting, appLaunch } =
    useAppInspector(client);
  const networkModel = useNetworkInspectorModel(client, networkServer, preferredKind === "network");

  return (
    <div className="window-frame">
      {isWaiting && !selection ? (
        <main className="inspector-loading-shell">
          <InspectorWaitingState launch={appLaunch} app={selectedApp} />
        </main>
      ) : preferredKind === "tweaks" && selection ? (
        <TweaksInspectorApp
          key={
            selectedApp
              ? `${selectedApp.deviceId}:${selectedApp.androidUserId ?? "unknown"}:${selectedApp.processName ?? selectedApp.id}`
              : selection.appId
          }
          client={client}
          selection={selection}
          isConnected={isConnected}
          selectedApp={selectedApp}
          appLaunch={appLaunch}
        />
      ) : (
        <NetworkInspectorApp model={networkModel} selectedApp={selectedApp} appLaunch={appLaunch} />
      )}
    </div>
  );
}
