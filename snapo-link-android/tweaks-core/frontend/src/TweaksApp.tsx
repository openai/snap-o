import type { JSX } from "preact";
import { useEffect, useMemo } from "preact/hooks";
import { createTweaksClient } from "./features/tweaks-inspector/client";
import { TweaksInspectorApp } from "./features/tweaks-inspector/TweaksInspectorApp";
import { InspectorWaitingState } from "./features/app-inspector/components/InspectorWaitingState";
import { useInspectorMetadata } from "./features/app-inspector/useInspectorMetadata";
import { supportedProtocolVersion, unsupportedProtocolMessage } from "./features/tweaks-inspector/protocol";

export function TweaksApp(): JSX.Element {
  const client = useMemo(() => createTweaksClient(), []);
  useEffect(() => () => client.dispose(), [client]);
  const { connected, revision, metadata } = useInspectorMetadata();
  return (
    <div className="window-frame">
      {metadata ? (
        metadata.protocolVersion === supportedProtocolVersion ? (
          <TweaksInspectorApp client={client} isConnected={connected} connectionRevision={revision} />
        ) : (
          <main className="inspector-loading-shell">
            <p className="inspector-open-error" role="alert">
              {unsupportedProtocolMessage(metadata.protocolVersion)}
            </p>
          </main>
        )
      ) : (
        <main className="inspector-loading-shell">
          <InspectorWaitingState />
        </main>
      )}
    </div>
  );
}
