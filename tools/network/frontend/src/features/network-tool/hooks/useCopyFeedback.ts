import { useCallback, useEffect, useMemo, useState } from "preact/hooks";
import type { ToolContentClient } from "../../../network/client";

export function useCopyFeedback(
  client: ToolContentClient,
  text: string
): { copied: boolean; copy: () => void; copyWithoutClipboard: () => void } {
  const [token, setToken] = useState(0);

  useEffect(() => {
    if (token === 0) return;
    const active = token;
    const timer = window.setTimeout(() => {
      setToken((current) => (current === active ? 0 : current));
    }, 1_000);
    return () => window.clearTimeout(timer);
  }, [token, text]);

  const copy = useCallback(() => {
    void client.copyText(text).then(() => setToken((current) => current + 1));
  }, [client, text]);
  const copyWithoutClipboard = useCallback(() => setToken((current) => current + 1), []);
  return useMemo(() => ({ copied: token !== 0, copy, copyWithoutClipboard }), [token, copy, copyWithoutClipboard]);
}
