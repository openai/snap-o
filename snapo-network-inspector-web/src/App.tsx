import { LoaderCircle } from "lucide-react";
import { useMemo } from "react";
import { createNetworkClient } from "./network/client";
import { NetworkInspectorApp } from "./features/network-inspector/NetworkInspectorApp";
import { useNetworkInspectorModel } from "./features/network-inspector/hooks/useNetworkInspectorModel";
import { TweaksInspectorApp } from "./features/tweaks-inspector/TweaksInspectorApp";
import { AppInspectorPicker } from "./features/app-inspector/components/AppInspectorPicker";
import { isInspectorMetadataPending } from "./features/app-inspector/selection";
import { useAppInspector } from "./features/app-inspector/useAppInspector";

export function App(): JSX.Element {
  const client = useMemo(() => createNetworkClient(), []);
  const {
    apps,
    selection,
    displayedNetwork,
    displayedTweaks,
    selectedApp,
    preferredKind,
    isRestoring,
    loading,
    select
  } = useAppInspector(client);
  const pending =
    loading ||
    isRestoring ||
    (selection != null && isInspectorMetadataPending(selection, client.usesNativeServerPicker));
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
          {!client.usesNativeServerPicker ? (
            <AppInspectorPicker
              apps={apps}
              selection={selection}
              selectedApp={selectedApp}
              preferredKind={preferredKind}
              onSelect={select}
            />
          ) : null}
          <div className="inspector-loading" role="status" aria-label="Connecting to inspector">
            <LoaderCircle className="body-loading-spinner" size={20} aria-hidden="true" />
          </div>
        </main>
      ) : displayedTweaks ? (
        <TweaksInspectorApp
          key={
            selectedApp ? `${selectedApp.deviceId}:${selectedApp.processName ?? selectedApp.id}` : displayedTweaks.appId
          }
          client={client}
          apps={apps}
          selection={displayedTweaks}
          isConnected={selection?.kind === "tweaks" && !pending}
          selectedApp={selectedApp}
          onSelect={select}
        />
      ) : (
        <NetworkInspectorApp
          model={networkModel}
          inspectorApps={apps}
          inspectorSelection={displayedNetwork}
          selectedApp={selectedApp}
          preferredKind={preferredKind}
          onInspectorSelect={select}
        />
      )}
    </div>
  );
}
