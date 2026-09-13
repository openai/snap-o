import type { JSX } from "preact";
import { useEffect, useMemo } from "preact/hooks";
import { createTweaksClient } from "./features/tweaks-tool/client";
import { TweaksToolApp } from "./features/tweaks-tool/TweaksToolApp";
import { host } from "@snap-o/tool-host";
import { useHostConnection } from "./useHostConnection";

export function TweaksApp(): JSX.Element {
  const client = useMemo(() => createTweaksClient(), []);
  useEffect(() => () => client.dispose(), [client]);
  const connection = useHostConnection(host);
  return (
    <div className="window-frame">
      <TweaksToolApp client={client} connection={connection} />
    </div>
  );
}
