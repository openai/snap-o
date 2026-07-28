import { type Dispatch, type SetStateAction, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createNetworkClient, type NetworkClient } from "../../../network/client";
import { bodyLoadPriority, RequestBodyLoader, type BodyLoadJob } from "../../../network/body-loader";
import { hydratedBodyRetentionLimitBytes, RequestBodyCache } from "../../../network/body-retention";
import {
  applyRequestBodies,
  createEmptyInspectorState,
  recordId,
  reduceCdpMessage,
  requestRecordKey,
  type InspectorDataState,
  type InspectorRecord,
  type ServerId
} from "../../../network/cdp";
import type { DebugInspectorPreset, SnapOServer } from "../../../network/bridge-types";
import { NetworkStreamController, type StreamLifecycleState } from "../../../network/stream-controller";
import { useInspectorUiState } from "./useInspectorUiState";
import { applyDebugInspectorPreset } from "../lib/debug";
import { copyCurl, exportAsHar } from "../lib/exportActions";
import { loadHiddenHosts, normalizeHiddenHost, normalizeHiddenHosts, saveHiddenHosts } from "../lib/hostFilters";
import {
  clearCompleted,
  countRecordsForServer,
  filterRecords,
  isCompletedRecord,
  mergeServersWithRetainedSelection,
  pickSelectedServer,
  replacementCandidate,
  serverModelFor,
  shouldRequestRequestBody,
  shouldRequestResponseBody,
  sidebarPlaceholderText
} from "../lib/records";

const docsUrl = "https://openai.github.io/snap-o/network-inspector.html";

export interface NetworkInspectorModel {
  client: NetworkClient;
  uiState: ReturnType<typeof useInspectorUiState>;
  servers: SnapOServer[];
  selectedServer: SnapOServer | null;
  selectedRecord: InspectorRecord | null;
  selectedRecordId: string | null;
  replacementServer: SnapOServer | null;
  visibleRecords: InspectorRecord[];
  allRecords: InspectorRecord[];
  sidebarPlaceholder: string | null;
  searchText: string;
  hiddenHosts: string[];
  sortNewestFirst: boolean;
  serverRecordCount: number;
  hasClearableItems: boolean;
  streamIsRetrying: boolean;
  selectServer(server: ServerId | null): void;
  selectReplacementServer(server: SnapOServer): void;
  selectRecord(id: string): void;
  setSearchText(value: string): void;
  addHiddenHost(value: string): void;
  removeHiddenHost(host: string): void;
  toggleSortOrder(): void;
  clearCompletedRecords(): void;
  retryResponseBody(): void;
  openDocs(): void;
}

export function useNetworkInspectorModel(
  controlledServer?: ServerId | null,
  isActive = true,
  allowsConnection = true
): NetworkInspectorModel {
  const client = useMemo(() => createNetworkClient(), []);
  const [state, setState] = useState<InspectorDataState>(() => createEmptyInspectorState());
  const [preferredServer, setPreferredServer] = useState<ServerId | null>(null);
  const hostPreferredDeviceIdRef = useRef<string | null>(null);
  const serversRef = useRef<SnapOServer[]>([]);
  const selectedServerRef = useRef<ServerId | null>(null);
  const [preferredRecordId, setPreferredRecordId] = useState<string | null>(null);
  const [searchText, setSearchText] = useState("");
  const [hiddenHosts, setHiddenHosts] = useState<string[]>(() =>
    client.usesNativeServerPicker ? [] : loadHiddenHosts()
  );
  const [sortNewestFirst, setSortNewestFirst] = useState(false);
  const [debugPreset, setDebugPreset] = useState<DebugInspectorPreset>("live");
  const [, setBodyCacheRevision] = useState(0);
  const [streamLifecycle, setStreamLifecycle] = useState<{
    connectionKey: string;
    state: StreamLifecycleState;
  } | null>(null);
  const uiState = useInspectorUiState();
  const [bodyHydration] = useState(() =>
    createBodyHydrationRuntime(client, () => setBodyCacheRevision((revision) => revision + 1))
  );
  const { bodyCache, bodyLoader } = bodyHydration;
  const toggleSortOrder = useCallback(() => setSortNewestFirst((value) => !value), []);
  const clearCompletedRecords = useCallback(() => setState(clearCompleted), []);
  const addHiddenHost = useCallback(
    (value: string) => {
      const host = normalizeHiddenHost(value);
      if (host == null) return;

      setHiddenHosts((current) => (current.includes(host) ? current : [...current, host].sort()));

      if (client.usesNativeServerPicker) {
        void client.addHiddenHost(host).catch(() => {
          void client.listHiddenHosts().then(
            (hosts) => setHiddenHosts(normalizeHiddenHosts(hosts)),
            () => {}
          );
        });
      }
    },
    [client]
  );
  const removeHiddenHost = useCallback((host: string) => {
    setHiddenHosts((current) => current.filter((value) => value !== host));
  }, []);

  useEffect(() => {
    return () => bodyLoader.dispose();
  }, [bodyLoader]);

  const selectedServer = useMemo(
    () => (controlledServer === undefined ? pickSelectedServer(preferredServer, state.servers) : controlledServer),
    [controlledServer, preferredServer, state.servers]
  );
  const selectServer = useCallback((server: ServerId | null) => {
    setPreferredServer(server);
    setPreferredRecordId(null);
  }, []);

  useEffect(() => {
    selectedServerRef.current = selectedServer;
    if (isActive && selectedServer != null) client.selectedDeviceChanged(selectedServer.deviceId);
  }, [client, isActive, selectedServer]);

  useEffect(
    () =>
      client.onPreferredDevice((deviceId) => {
        hostPreferredDeviceIdRef.current = deviceId;
        selectDeviceServer(deviceId, serversRef.current, setPreferredServer);
      }),
    [client]
  );

  useEffect(() => client.onNativeSelectedServer(selectServer), [client, selectServer]);
  useEffect(() => client.onNativeSearchText(setSearchText), [client]);
  useEffect(() => client.onNativeHiddenHosts(setHiddenHosts), [client]);
  useEffect(() => client.onNativeSortOrder(setSortNewestFirst), [client]);
  useEffect(() => {
    if (isActive) return client.onNativeClearCompleted(clearCompletedRecords);
  }, [clearCompletedRecords, client, isActive]);

  useEffect(() => {
    if (!client.usesNativeServerPicker) return;

    let disposed = false;
    void client.listHiddenHosts().then(
      (hosts) => {
        if (!disposed) setHiddenHosts(normalizeHiddenHosts(hosts));
      },
      () => {}
    );

    return () => {
      disposed = true;
    };
  }, [client]);

  useEffect(() => {
    if (!client.usesNativeServerPicker) saveHiddenHosts(hiddenHosts);
  }, [client, hiddenHosts]);

  useEffect(() => {
    const unsubscribeEvent = client.onEvent((event) => {
      setState((current) =>
        reduceCdpMessage(current, { ...event.server, instanceId: event.serverInstanceId }, event.message)
      );
    });
    return unsubscribeEvent;
  }, [client]);

  useEffect(() => {
    let disposed = false;
    void client.debugInspectorPreset().then((preset) => {
      if (!disposed) setDebugPreset(preset);
    });
    const unsubscribe = client.onDebugInspectorPreset(setDebugPreset);
    return () => {
      disposed = true;
      unsubscribe();
    };
  }, [client]);

  useEffect(() => {
    if (!isActive) return;
    let disposed = false;
    const refresh = async () => {
      const activeServers = await client.listServers();
      if (disposed) return;
      serversRef.current = activeServers;
      if (hostPreferredDeviceIdRef.current != null) {
        selectDeviceServer(hostPreferredDeviceIdRef.current, activeServers, setPreferredServer);
      }

      setState((current) => {
        const servers = mergeServersWithRetainedSelection(activeServers, current.servers, selectedServerRef.current);
        return areServersEqual(current.servers, servers) ? current : { ...current, servers };
      });
    };

    void refresh();
    const timer = window.setInterval(() => void refresh(), 2_000);
    return () => {
      disposed = true;
      window.clearInterval(timer);
    };
  }, [client, isActive]);

  const selectedServerKey = serverKey(selectedServer);
  const displayServers = useMemo(
    () =>
      applyDebugInspectorPreset(state.servers, selectedServer, debugPreset).map((server) =>
        !allowsConnection &&
        server.deviceId === selectedServer?.deviceId &&
        server.socketName === selectedServer.socketName
          ? { ...server, isConnected: false }
          : server
      ),
    [allowsConnection, debugPreset, selectedServer, state.servers]
  );
  const selectedServerModel = useMemo(
    () => serverModelFor(displayServers, selectedServer),
    [displayServers, selectedServer]
  );

  const selectedServerIsConnected = selectedServerModel?.isConnected === true;
  const selectedServerConnectionKey =
    selectedServerModel == null
      ? selectedServerKey
      : `${selectedServerKey}\u0000${selectedServerModel.instanceId ?? ""}\u0000${selectedServerModel.isConnected}\u0000${selectedServerModel.hasAppInfo}`;
  const streamIsRetrying =
    streamLifecycle?.connectionKey === selectedServerConnectionKey && streamLifecycle.state === "retrying";

  useEffect(() => {
    if (!isActive || selectedServer == null || !selectedServerIsConnected) return;
    const connectionKey = selectedServerConnectionKey;
    const controller = new NetworkStreamController(client, selectedServer, (state) => {
      setStreamLifecycle({ connectionKey, state });
    });
    controller.start();
    return () => controller.dispose();
  }, [client, isActive, selectedServer, selectedServerConnectionKey, selectedServerIsConnected]);

  const allRecords = hydrateCachedBodies([...state.requests.values(), ...state.webSockets.values()], bodyCache);

  const visibleRecords = useMemo(
    () => filterRecords(allRecords, selectedServer, searchText, sortNewestFirst, hiddenHosts),
    [allRecords, hiddenHosts, searchText, selectedServer, sortNewestFirst]
  );

  const serverRecordCount = useMemo(
    () => countRecordsForServer(allRecords, selectedServer),
    [allRecords, selectedServer]
  );

  const selectedRecordId = useMemo(() => {
    if (visibleRecords.length === 0) return null;
    if (preferredRecordId != null && visibleRecords.some((record) => recordId(record) === preferredRecordId)) {
      return preferredRecordId;
    }
    return recordId(visibleRecords[0]);
  }, [preferredRecordId, visibleRecords]);

  const selectedRecord = useMemo(() => {
    if (selectedRecordId == null) return null;
    return visibleRecords.find((record) => recordId(record) === selectedRecordId) ?? null;
  }, [selectedRecordId, visibleRecords]);
  const selectedRequestKey = selectedRecord?.kind === "request" ? selectedRecordId : null;

  const retryResponseBody = useCallback(() => {
    if (selectedRecord?.kind !== "request" || selectedRecord.responseBodyLoadError !== "failed") return;
    const recordKey = requestRecordKey(selectedRecord.server, selectedRecord.requestId);
    bodyLoader.forgetJob(`${recordKey}\u0000response`);
    bodyLoader.forgetRecords(
      bodyCache.put(recordKey, {
        requestId: selectedRecord.requestId,
        responseBodyLoadCompleted: false,
        responseBodyLoadError: null
      })
    );
    setBodyCacheRevision((revision) => revision + 1);
  }, [bodyCache, bodyLoader, selectedRecord]);

  useEffect(() => {
    if (!isActive) return;
    bodyLoader.forgetRecords(bodyCache.select(selectedRequestKey));
  }, [bodyCache, bodyLoader, isActive, selectedRequestKey]);

  useEffect(() => {
    const jobs: BodyLoadJob[] = [];
    const retainedRecordKeys = new Set(state.requests.keys());
    bodyLoader.forgetRecords(bodyCache.retainRecords(retainedRecordKeys));

    if (isActive && selectedServerIsConnected && selectedRecord?.kind === "request") {
      const recordKey = requestRecordKey(selectedRecord.server, selectedRecord.requestId);
      const requestAttemptKey = `${recordKey}\u0000request`;
      const responseAttemptKey = `${recordKey}\u0000response`;

      if (shouldRequestRequestBody(selectedRecord)) {
        jobs.push({
          key: requestAttemptKey,
          recordKey,
          priority: bodyLoadPriority.selected,
          input: {
            deviceId: selectedRecord.server.deviceId,
            socketName: selectedRecord.server.socketName,
            serverInstanceId: selectedRecord.server.instanceId,
            requestId: selectedRecord.requestId,
            includeRequestBody: true,
            includeResponseBody: false
          }
        });
      }

      if (shouldRequestResponseBody(selectedRecord)) {
        jobs.push({
          key: responseAttemptKey,
          recordKey,
          priority: bodyLoadPriority.selected,
          input: {
            deviceId: selectedRecord.server.deviceId,
            socketName: selectedRecord.server.socketName,
            serverInstanceId: selectedRecord.server.instanceId,
            requestId: selectedRecord.requestId,
            includeRequestBody: false,
            includeResponseBody: true
          }
        });
      }
    }

    bodyLoader.retainRecords(retainedRecordKeys);
    bodyLoader.schedule(jobs);
  }, [bodyCache, bodyLoader, isActive, selectedRecord, selectedServerIsConnected, state.requests]);

  const replacementServer = useMemo(
    () => replacementCandidate(displayServers, selectedServerModel),
    [displayServers, selectedServerModel]
  );
  const sidebarPlaceholder = useMemo(
    () =>
      sidebarPlaceholderText({
        totalItems: allRecords.length,
        serverScopedItems: serverRecordCount,
        filteredItems: visibleRecords.length,
        selectedServer: selectedServerModel,
        streamIsRetrying
      }),
    [allRecords.length, selectedServerModel, serverRecordCount, streamIsRetrying, visibleRecords.length]
  );
  const hasClearableItems = useMemo(() => allRecords.some(isCompletedRecord), [allRecords]);
  const selectedRecordKind = selectedRecord?.kind ?? null;
  const hasVisibleRecords = visibleRecords.length > 0;

  useEffect(
    () =>
      client.onNativeCopySelectedUrl(() => {
        if (isActive && selectedRecord != null) void client.copyText(selectedRecord.url);
      }),
    [client, isActive, selectedRecord]
  );
  useEffect(
    () =>
      client.onNativeCopySelectedCurl(() => {
        if (isActive && selectedRecord?.kind === "request")
          void copyCurl(client, selectedRecord, selectedServerIsConnected);
      }),
    [client, isActive, selectedRecord, selectedServerIsConnected]
  );
  useEffect(
    () =>
      client.onNativeExportVisibleHar(() => {
        if (isActive) void exportAsHar(client, visibleRecords, undefined, selectedServerIsConnected);
      }),
    [client, isActive, selectedServerIsConnected, visibleRecords]
  );

  useEffect(() => {
    if (!isActive) return;
    client.nativeInspectorStateChanged({
      servers: displayServers,
      selectedServer:
        selectedServerModel == null
          ? null
          : { deviceId: selectedServerModel.deviceId, socketName: selectedServerModel.socketName },
      searchText,
      sortNewestFirst,
      hasClearableItems,
      selectedRecordKind,
      hasVisibleRecords
    });
  }, [
    client,
    isActive,
    displayServers,
    hasClearableItems,
    hasVisibleRecords,
    searchText,
    selectedRecordKind,
    selectedServerModel,
    sortNewestFirst
  ]);

  const selectReplacementServer = useCallback(
    (server: SnapOServer) => selectServer({ deviceId: server.deviceId, socketName: server.socketName }),
    [selectServer]
  );
  const selectRecord = useCallback((id: string) => setPreferredRecordId(id), []);
  const openDocs = useCallback(() => void client.openExternal(docsUrl), [client]);

  return {
    client,
    uiState,
    servers: displayServers,
    selectedServer: selectedServerModel,
    selectedRecord,
    selectedRecordId,
    replacementServer,
    visibleRecords,
    allRecords,
    sidebarPlaceholder,
    searchText,
    hiddenHosts,
    sortNewestFirst,
    serverRecordCount,
    hasClearableItems,
    streamIsRetrying,
    selectServer,
    selectReplacementServer,
    selectRecord,
    setSearchText,
    addHiddenHost,
    removeHiddenHost,
    toggleSortOrder,
    clearCompletedRecords,
    retryResponseBody,
    openDocs
  };
}

function createBodyHydrationRuntime(
  client: NetworkClient,
  didChangeCache: () => void
): {
  bodyCache: RequestBodyCache;
  bodyLoader: RequestBodyLoader;
} {
  const bodyCache = new RequestBodyCache(hydratedBodyRetentionLimitBytes);
  const bodyLoader = new RequestBodyLoader(
    (input) => client.loadBodies(input),
    (recordKey, bodies) => {
      bodyLoader.forgetRecords(bodyCache.put(recordKey, bodies));
      didChangeCache();
    }
  );
  return { bodyCache, bodyLoader };
}

function hydrateCachedBodies(records: InspectorRecord[], bodyCache: RequestBodyCache): InspectorRecord[] {
  return records.map((record) => {
    if (record.kind !== "request") return record;
    const bodies = bodyCache.peek(requestRecordKey(record.server, record.requestId));
    return bodies == null ? record : applyRequestBodies(record, bodies);
  });
}

function selectDeviceServer(
  deviceId: string,
  servers: SnapOServer[],
  setPreferredServer: Dispatch<SetStateAction<ServerId | null>>
): void {
  setPreferredServer((current) => {
    if (current?.deviceId === deviceId) return current;
    const match = servers.find((server) => server.deviceId === deviceId);
    return match == null ? current : { deviceId: match.deviceId, socketName: match.socketName };
  });
}

function serverKey(server: ServerId | null): string {
  return server == null ? "" : `${server.deviceId}\u0000${server.socketName}`;
}

function areServersEqual(left: SnapOServer[], right: SnapOServer[]): boolean {
  if (left.length !== right.length) return false;
  return left.every((server, index) => areServerModelsEqual(server, right[index]));
}

function areServerModelsEqual(left: SnapOServer, right: SnapOServer | undefined): boolean {
  if (right == null) return false;
  return (
    left.server === right.server &&
    left.deviceId === right.deviceId &&
    left.socketName === right.socketName &&
    left.displayName === right.displayName &&
    left.deviceDisplayTitle === right.deviceDisplayTitle &&
    left.appIconBase64 === right.appIconBase64 &&
    left.isConnected === right.isConnected &&
    left.hasAppInfo === right.hasAppInfo &&
    left.pid === right.pid &&
    (left.instanceId ?? null) === (right.instanceId ?? null) &&
    left.protocolVersion === right.protocolVersion &&
    left.isProtocolNewerThanSupported === right.isProtocolNewerThanSupported &&
    left.isProtocolOlderThanSupported === right.isProtocolOlderThanSupported &&
    left.packageName === right.packageName &&
    left.appName === right.appName
  );
}
