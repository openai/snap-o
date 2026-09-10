import { useCallback, useEffect, useMemo, useState } from "preact/hooks";
import { type NetworkClient } from "../../../network/client";
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
import { ExclusionFiltersRevision, normalizeExclusionFilter, normalizeExclusionFilters } from "../lib/exclusionFilters";
import {
  clearCompleted,
  countExcludedRecordsForServer,
  countRecordsForServer,
  filterRecords,
  isCompletedRecord,
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
  visibleRecords: InspectorRecord[];
  allRecords: InspectorRecord[];
  sidebarPlaceholder: string | null;
  searchText: string;
  exclusionFilters: string[];
  hiddenRequestCount: number;
  sortNewestFirst: boolean;
  serverRecordCount: number;
  hasClearableItems: boolean;
  streamIsRetrying: boolean;
  selectRecord(id: string): void;
  addExclusionFilter(value: string): void;
  removeExclusionFilter(filter: string): void;
  retryResponseBody(): void;
  openDocs(): void;
}

export function useNetworkInspectorModel(
  client: NetworkClient,
  hostServer: SnapOServer | null,
  isActive: boolean
): NetworkInspectorModel {
  const [state, setState] = useState<InspectorDataState>(() => createEmptyInspectorState());
  const [preferredRecordId, setPreferredRecordId] = useState<string | null>(null);
  const [searchText, setSearchText] = useState("");
  const [exclusionFilters, setExclusionFilters] = useState<string[]>([]);
  const [exclusionFiltersRevision] = useState(() => new ExclusionFiltersRevision());
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
  const clearCompletedRecords = useCallback(() => setState(clearCompleted), []);
  const addExclusionFilter = useCallback(
    (value: string) => {
      const filter = normalizeExclusionFilter(value);
      if (filter == null) return;

      exclusionFiltersRevision.invalidate();
      setExclusionFilters((current) => (current.includes(filter) ? current : [...current, filter].sort()));

      void client.addExclusionFilter(filter).catch(() => {
        const revision = exclusionFiltersRevision.capture();
        void client.listExclusionFilters().then(
          (filters) => {
            if (exclusionFiltersRevision.isCurrent(revision)) setExclusionFilters(normalizeExclusionFilters(filters));
          },
          () => {}
        );
      });
    },
    [client, exclusionFiltersRevision]
  );
  const removeExclusionFilter = useCallback(
    (filter: string) => {
      exclusionFiltersRevision.invalidate();
      setExclusionFilters((current) => current.filter((value) => value !== filter));

      void client.removeExclusionFilter(filter).catch(() => {
        const revision = exclusionFiltersRevision.capture();
        void client.listExclusionFilters().then(
          (filters) => {
            if (exclusionFiltersRevision.isCurrent(revision)) setExclusionFilters(normalizeExclusionFilters(filters));
          },
          () => {}
        );
      });
    },
    [client, exclusionFiltersRevision]
  );

  useEffect(() => {
    return () => bodyLoader.dispose();
  }, [bodyLoader]);

  const deviceId = hostServer?.deviceId;
  const socketName = hostServer?.socketName;
  const selectedServer = useMemo(
    () => (deviceId == null || socketName == null ? null : { deviceId, socketName }),
    [deviceId, socketName]
  );

  useEffect(() => client.onNativeSearchText(setSearchText), [client]);
  useEffect(
    () =>
      client.onNativeExclusionFilters((filters) => {
        exclusionFiltersRevision.invalidate();
        setExclusionFilters(normalizeExclusionFilters(filters));
      }),
    [client, exclusionFiltersRevision]
  );
  useEffect(() => client.onNativeSortOrder(setSortNewestFirst), [client]);
  useEffect(() => {
    if (isActive) return client.onNativeClearCompleted(clearCompletedRecords);
  }, [clearCompletedRecords, client, isActive]);

  useEffect(() => {
    let disposed = false;
    const revision = exclusionFiltersRevision.capture();
    void client.listExclusionFilters().then(
      (filters) => {
        if (!disposed && exclusionFiltersRevision.isCurrent(revision)) {
          setExclusionFilters(normalizeExclusionFilters(filters));
        }
      },
      () => {}
    );

    return () => {
      disposed = true;
    };
  }, [client, exclusionFiltersRevision]);

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

  const selectedServerKey = serverKey(selectedServer);
  const displayServers = useMemo(
    () => applyDebugInspectorPreset(hostServer == null ? [] : [hostServer], selectedServer, debugPreset),
    [debugPreset, hostServer, selectedServer]
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
    () => filterRecords(allRecords, selectedServer, searchText, sortNewestFirst, exclusionFilters),
    [allRecords, exclusionFilters, searchText, selectedServer, sortNewestFirst]
  );

  const hiddenRequestCount = useMemo(
    () => countExcludedRecordsForServer(allRecords, selectedServer, exclusionFilters),
    [allRecords, exclusionFilters, selectedServer]
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
    hasClearableItems,
    hasVisibleRecords,
    searchText,
    selectedRecordKind,
    selectedServerModel,
    sortNewestFirst
  ]);

  const selectRecord = useCallback((id: string) => setPreferredRecordId(id), []);
  const openDocs = useCallback(() => void client.openExternal(docsUrl), [client]);

  return {
    client,
    uiState,
    servers: displayServers,
    selectedServer: selectedServerModel,
    selectedRecord,
    selectedRecordId,
    visibleRecords,
    allRecords,
    sidebarPlaceholder,
    searchText,
    exclusionFilters,
    hiddenRequestCount,
    sortNewestFirst,
    serverRecordCount,
    hasClearableItems,
    streamIsRetrying,
    selectRecord,
    addExclusionFilter,
    removeExclusionFilter,
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

function serverKey(server: ServerId | null): string {
  return server == null ? "" : `${server.deviceId}\u0000${server.socketName}`;
}
