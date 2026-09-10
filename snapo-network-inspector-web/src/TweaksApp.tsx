import type { JSX } from "preact";
import { useMemo } from "preact/hooks";
import { createTweaksClient } from "./features/tweaks-inspector/client";
import { TweaksInspectorApp } from "./features/tweaks-inspector/TweaksInspectorApp";
import { InspectorWaitingState } from "./features/app-inspector/components/InspectorWaitingState";
import { useAppInspector } from "./features/app-inspector/useAppInspector";

export function TweaksApp(): JSX.Element {
  const client = useMemo(() => createTweaksClient(), []);
  const { selection, selectedApp, isConnected, appLaunch } = useAppInspector(client);

  return (
    <div className="window-frame">
      {selection ? (
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
        <main className="inspector-loading-shell">
          <InspectorWaitingState launch={appLaunch} app={selectedApp} />
        </main>
      )}
    </div>
  );
}
