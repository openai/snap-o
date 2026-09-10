import type { JSX } from "preact";
import { useEffect, useMemo } from "preact/hooks";
import { createTweaksClient } from "./features/tweaks-inspector/client";
import { TweaksInspectorApp } from "./features/tweaks-inspector/TweaksInspectorApp";
import { InspectorWaitingState } from "./features/app-inspector/components/InspectorWaitingState";
import { useInspectorMetadata } from "./features/app-inspector/useInspectorMetadata";

const server = { deviceId: "inspector", socketName: "tweaks" };

export function TweaksApp(): JSX.Element {
  const client = useMemo(() => createTweaksClient(), []);
  useEffect(() => () => client.dispose(), [client]);
  const { connected, revision, metadata } = useInspectorMetadata();
  const selection = useMemo(
    () =>
      metadata && {
        appId: metadata.packageName,
        kind: "tweaks" as const,
        server,
        protocolVersion: metadata.protocolVersion
      },
    [metadata]
  );
  return (
    <div className="window-frame">
      {selection ? (
        <TweaksInspectorApp
          client={client}
          selection={selection}
          isConnected={connected}
          connectionRevision={revision}
        />
      ) : (
        <main className="inspector-loading-shell">
          <InspectorWaitingState />
        </main>
      )}
    </div>
  );
}
