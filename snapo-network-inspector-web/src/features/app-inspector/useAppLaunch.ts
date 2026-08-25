import { useCallback, useEffect, useRef, useState } from "react";
import type { InspectableApp, OpenAppInput } from "../../network/bridge-types";
import type { NetworkClient } from "../../network/client";

export interface AppLaunchControl {
  pending: boolean;
  error: string | null;
  open(): void;
}

interface LaunchAttempt {
  opening: boolean;
  waiting: boolean;
  timeout?: number;
  interval?: number;
}

function appKey(app: InspectableApp | null): string | null {
  return app
    ? `${app.deviceId}:${app.androidUserId ?? "unknown"}:${app.processName ?? app.packageName ?? app.id}`
    : null;
}

function launchInput(app: InspectableApp | null): OpenAppInput | null {
  if (!app?.packageName || app.androidUserId == null || !Number.isInteger(app.androidUserId) || app.androidUserId < 0) {
    return null;
  }
  return { deviceId: app.deviceId, packageName: app.packageName, androidUserId: app.androidUserId };
}

export function useAppLaunch(client: NetworkClient, selectedApp: InspectableApp | null, refresh: () => void) {
  const [launchState, setLaunchState] = useState<{ key: string; pending: boolean; error: string | null } | null>(null);
  const activeLaunch = useRef<LaunchAttempt | null>(null);
  const currentApp = useRef(selectedApp);

  const cancelLaunch = useCallback(() => {
    const attempt = activeLaunch.current;
    if (attempt) {
      window.clearTimeout(attempt.timeout);
      window.clearInterval(attempt.interval);
      activeLaunch.current = null;
    }
  }, []);

  const reconcileSelection = useCallback(
    (app: InspectableApp | null) => {
      const previous = currentApp.current;
      currentApp.current = app;
      // Native selection changes must cancel a launch before React renders the next app.
      if (appKey(previous) !== appKey(app)) {
        cancelLaunch();
        setLaunchState(null);
      }
    },
    [cancelLaunch]
  );

  const openSelectedApp = useCallback(async () => {
    const app = currentApp.current;
    const key = appKey(app);
    const input = launchInput(app);
    if (!app || !key || !input || !client.openApp || activeLaunch.current) return;

    const attempt: LaunchAttempt = { opening: true, waiting: true };
    activeLaunch.current = attempt;
    setLaunchState({ key, pending: true, error: null });
    attempt.timeout = window.setTimeout(() => {
      if (activeLaunch.current !== attempt) return;
      attempt.waiting = false;
      window.clearInterval(attempt.interval);
      refresh();
      if (!attempt.opening) activeLaunch.current = null;
      setLaunchState({ key, pending: attempt.opening, error: null });
    }, 5_000);
    attempt.interval = window.setInterval(refresh, 500);

    try {
      await client.openApp(input);
      if (activeLaunch.current !== attempt) return;
      attempt.opening = false;
      if (!attempt.waiting) activeLaunch.current = null;
      setLaunchState({ key, pending: attempt.waiting, error: null });
      refresh();
    } catch (cause) {
      if (activeLaunch.current !== attempt) return;
      cancelLaunch();
      setLaunchState({
        key,
        pending: false,
        error: cause instanceof Error ? cause.message : `Unable to open ${app.name}.`
      });
    }
  }, [cancelLaunch, client, refresh]);

  useEffect(() => cancelLaunch, [cancelLaunch, client]);

  const isPolling = useCallback(() => activeLaunch.current?.waiting === true, []);
  const currentLaunch = launchState?.key === appKey(selectedApp) ? launchState : null;
  const appLaunch: AppLaunchControl | null =
    launchInput(selectedApp) && client.openApp
      ? {
          pending: currentLaunch?.pending ?? false,
          error: currentLaunch?.error ?? null,
          open: () => void openSelectedApp()
        }
      : null;

  return { appLaunch, reconcileSelection, isPolling };
}
