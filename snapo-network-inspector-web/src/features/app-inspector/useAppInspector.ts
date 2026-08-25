import { useCallback, useEffect, useRef, useState } from "react";
import type { AppInspectorOption, InspectableApp } from "../../network/bridge-types";
import type { NetworkClient } from "../../network/client";
import { InspectorRestoration } from "./restoration";
import { useAppLaunch } from "./useAppLaunch";

export function useAppInspector(client: NetworkClient) {
  const [owner] = useState(() => new InspectorRestoration());
  const [state, setState] = useState(() => owner.snapshot());
  const [loading, setLoading] = useState(true);
  const lastSaved = useRef<string | null>(null);
  const saveQueue = useRef(Promise.resolve());
  const requestRefresh = useRef<(() => void) | null>(null);
  const refreshNow = useCallback(() => requestRefresh.current?.(), []);
  const { appLaunch, reconcileSelection, isPolling } = useAppLaunch(client, state.selectedApp, refreshNow);

  const publish = useCallback(() => {
    const snapshot = owner.snapshot();
    reconcileSelection(snapshot.selectedApp);
    setState(snapshot);
    client.appInspectorStateChanged(snapshot);
    const saved = owner.serialize();
    if (saved !== lastSaved.current) {
      lastSaved.current = saved;
      saveQueue.current = saveQueue.current
        .then(() => client.saveInspectorPreferences(saved))
        .catch(() => {
          if (lastSaved.current === saved) lastSaved.current = null;
        });
    }
  }, [client, owner, reconcileSelection]);

  const select = useCallback(
    (app: InspectableApp, option?: AppInspectorOption) => {
      if (option) owner.selectInspector(app, option);
      else owner.selectApp(app);
      publish();
    },
    [owner, publish]
  );

  useEffect(() => {
    let disposed = false;
    let refreshing = false;
    let initialized = false;

    const refresh = async () => {
      if (!initialized || refreshing) return;
      refreshing = true;
      try {
        const apps = await client.listInspectorApps();
        if (disposed) return;
        owner.reconcile(apps);
        publish();
        setLoading(false);
      } catch {
        // A failed scan is not evidence that the user's chosen app has gone away.
      } finally {
        refreshing = false;
      }
    };
    requestRefresh.current = () => void refresh();

    const unsubscribeInspector = client.onNativeSelectedInspector((selection) => {
      const state = owner.snapshot();
      const app =
        state.selectedApp?.id === selection.appId
          ? state.selectedApp
          : state.apps.find((candidate) => candidate.id === selection.appId);
      const option = app?.inspectors.find((candidate) => candidate.kind === selection.kind);
      if (app && option) select(app, option);
    });
    const unsubscribeApp = client.onNativeSelectedApp((id) => {
      const app = owner.snapshot().apps.find((candidate) => candidate.id === id);
      if (app) select(app);
    });

    void client
      .loadInspectorPreferences()
      .catch(() => null)
      .then((saved) => {
        if (disposed) return;
        owner.hydrate(saved);
        lastSaved.current = saved;
        initialized = true;
        publish();
        void refresh();
      });
    const interval = window.setInterval(() => {
      if (!document.hidden && !isPolling()) void refresh();
    }, 2_500);
    return () => {
      disposed = true;
      requestRefresh.current = null;
      window.clearInterval(interval);
      unsubscribeInspector();
      unsubscribeApp();
    };
  }, [client, isPolling, owner, publish, select]);

  return { ...state, loading, select, appLaunch };
}
