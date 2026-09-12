import type { JSX } from "preact";
import { useEffect, useMemo } from "preact/hooks";
import { createTweaksClient } from "./features/tweaks-tool/client";
import { TweaksToolApp } from "./features/tweaks-tool/TweaksToolApp";
import { ToolWaitingState } from "./features/app-tool/components/ToolWaitingState";
import { usePluginMetadata } from "./features/app-tool/usePluginMetadata";
import { supportedProtocolVersion, unsupportedProtocolMessage } from "./features/tweaks-tool/protocol";

export function TweaksApp(): JSX.Element {
  const client = useMemo(() => createTweaksClient(), []);
  useEffect(() => () => client.dispose(), [client]);
  const { connected, revision, metadata } = usePluginMetadata();
  return (
    <div className="window-frame">
      {metadata ? (
        metadata.protocolVersion === supportedProtocolVersion ? (
          <TweaksToolApp client={client} isConnected={connected} connectionRevision={revision} />
        ) : (
          <main className="tool-loading-shell">
            <p className="tool-open-error" role="alert">
              {unsupportedProtocolMessage(metadata.protocolVersion)}
            </p>
          </main>
        )
      ) : (
        <main className="tool-loading-shell">
          <ToolWaitingState />
        </main>
      )}
    </div>
  );
}
