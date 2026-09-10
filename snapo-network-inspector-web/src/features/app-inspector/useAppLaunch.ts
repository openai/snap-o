import { useCallback, useEffect, useRef, useState } from "preact/hooks";
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
  const activeLaunchRef = useRef<LaunchAttempt | null>(null);
  const currentAppRef = useRef(selectedApp);

  const cancelLaunch = useCallback(() => {
    const attempt = activeLaunchRef.current;
    if (attempt) {
      window.clearTimeout(attempt.timeout);
      window.clearInterval(attempt.interval);
      activeLaunchRef.current = null;
    }
  }, []);

  const reconcileSelection = useCallback(
    (app: InspectableApp | null) => {
      const previous = currentAppRef.current;
      currentAppRef.current = app;
      // Native selection changes must cancel a launch before the inspector renders the next app.
      if (appKey(previous) !== appKey(app)) {
        cancelLaunch();
        setLaunchState(null);
      }
    },
    [cancelLaunch]
  );

  const openSelectedApp = useCallback(async () => {
    const app = currentAppRef.current;
    const key = appKey(app);
    const input = launchInput(app);
    if (!app || !key || !input || !client.openApp || activeLaunchRef.current) return;

    const attempt: LaunchAttempt = { opening: true, waiting: true };
    activeLaunchRef.current = attempt;
    setLaunchState({ key, pending: true, error: null });
    attempt.timeout = window.setTimeout(() => {
      if (activeLaunchRef.current !== attempt) return;
      attempt.waiting = false;
      window.clearInterval(attempt.interval);
      refresh();
      if (!attempt.opening) activeLaunchRef.current = null;
      setLaunchState({ key, pending: attempt.opening, error: null });
    }, 5_000);
    attempt.interval = window.setInterval(refresh, 500);

    try {
      await client.openApp(input);
      if (activeLaunchRef.current !== attempt) return;
      attempt.opening = false;
      if (!attempt.waiting) activeLaunchRef.current = null;
      setLaunchState({ key, pending: attempt.waiting, error: null });
      refresh();
    } catch (cause) {
      if (activeLaunchRef.current !== attempt) return;
      cancelLaunch();
      setLaunchState({
        key,
        pending: false,
        error: cause instanceof Error ? cause.message : `Unable to open ${app.name}.`
      });
    }
  }, [cancelLaunch, client, refresh]);

  useEffect(() => cancelLaunch, [cancelLaunch, client]);

  const isPolling = useCallback(() => activeLaunchRef.current?.waiting === true, []);
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
