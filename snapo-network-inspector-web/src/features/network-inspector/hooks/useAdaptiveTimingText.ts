import { useEffect, useState } from "react";
import type { RequestStatus } from "../../../network/cdp";
import { formatTiming } from "../lib/format";

export function useAdaptiveTimingText(startedAt: number, endedAt: number | undefined, status: RequestStatus): string {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    let timeoutId: number | null = null;
    const scheduleNextTick = () => {
      const elapsedSeconds = Math.max(0, Math.floor((Date.now() - startedAt) / 1_000));
      timeoutId = window.setTimeout(
        () => {
          setNow(Date.now());
          scheduleNextTick();
        },
        elapsedSeconds >= 60 ? 60_000 : 1_000
      );
    };

    scheduleNextTick();
    return () => {
      if (timeoutId != null) window.clearTimeout(timeoutId);
    };
  }, [startedAt]);

  return formatTiming(startedAt, endedAt, status, now);
}
