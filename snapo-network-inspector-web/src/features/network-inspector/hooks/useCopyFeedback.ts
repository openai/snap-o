import { useEffect, useState } from "react";
import type { NetworkClient } from "../../../network/client";

export function useCopyFeedback(
  client: NetworkClient,
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

  return {
    copied: token !== 0,
    copy: () => {
      void client.copyText(text).then(() => setToken((current) => current + 1));
    },
    copyWithoutClipboard: () => setToken((current) => current + 1)
  };
}
