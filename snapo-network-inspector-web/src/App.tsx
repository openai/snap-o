import type { JSX } from "preact";
import { useMemo } from "preact/hooks";
import { createNetworkClient } from "./network/client";
import { NetworkInspectorApp } from "./features/network-inspector/NetworkInspectorApp";
import { useNetworkInspectorModel } from "./features/network-inspector/hooks/useNetworkInspectorModel";
import { TweaksInspectorApp } from "./features/tweaks-inspector/TweaksInspectorApp";
import { InspectorWaitingState } from "./features/app-inspector/components/InspectorWaitingState";
import { isInspectorMetadataPending } from "./features/app-inspector/selection";
import { useAppInspector } from "./features/app-inspector/useAppInspector";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  const { apps, selection, displayedNetwork, displayedTweaks, selectedApp, isRestoring, loading, select, appLaunch } =
    useAppInspector(client);
  const pending = loading || isRestoring || (selection != null && isInspectorMetadataPending(selection));
  const showsNetwork = displayedNetwork != null || (!pending && selection?.kind !== "tweaks");
  const networkModel = useNetworkInspectorModel(
    displayedNetwork?.server ?? null,
    showsNetwork,
    selection?.kind === "network"
  );

  return (
    <div className="window-frame">
      {pending && !displayedNetwork && !displayedTweaks ? (
        <main className="inspector-loading-shell">
          <InspectorWaitingState launch={appLaunch} app={selectedApp} />
        </main>
      ) : displayedTweaks ? (
        <TweaksInspectorApp
          key={
            selectedApp
              ? `${selectedApp.deviceId}:${selectedApp.androidUserId ?? "unknown"}:${selectedApp.processName ?? selectedApp.id}`
              : displayedTweaks.appId
          }
          client={client}
          selection={displayedTweaks}
          isConnected={selection?.kind === "tweaks" && !pending}
          selectedApp={selectedApp}
          appLaunch={appLaunch}
        />
      ) : (
        <NetworkInspectorApp
          model={networkModel}
          inspectorApps={apps}
          selectedApp={selectedApp}
          appLaunch={appLaunch}
          onInspectorSelect={select}
        />
      )}
    </div>
  );
}
