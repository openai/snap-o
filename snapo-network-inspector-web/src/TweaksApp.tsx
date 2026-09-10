import type { JSX } from "preact";
import { useEffect, useMemo } from "preact/hooks";
import { createTweaksClient } from "./features/tweaks-inspector/client";
import { TweaksInspectorApp } from "./features/tweaks-inspector/TweaksInspectorApp";
import { InspectorWaitingState } from "./features/app-inspector/components/InspectorWaitingState";
import { useInspectorMetadata } from "./features/app-inspector/useInspectorMetadata";

export function TweaksApp(): JSX.Element {
  const client = useMemo(() => createTweaksClient(), []);
  useEffect(() => () => client.dispose(), [client]);
  const { connected, revision, metadata } = useInspectorMetadata();
  return (
    <div className="window-frame">
      {metadata ? (
        <TweaksInspectorApp client={client} metadata={metadata} isConnected={connected} connectionRevision={revision} />
      ) : (
        <main className="inspector-loading-shell">
          <InspectorWaitingState />
        </main>
      )}
    </div>
  );
}
