import { host } from "@snap-o/host";
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
  type InspectorRecord
} from "../../../network/cdp";
import type { InspectorMetadata } from "../../app-inspector/useInspectorMetadata";
import { supportedProtocolVersion } from "../lib/protocol";
import { NetworkStreamController, type StreamLifecycleState } from "../../../network/stream-controller";
import { useInspectorUiState } from "./useInspectorUiState";
import { exportAsHar } from "../lib/exportActions";
import { ExclusionFiltersRevision, normalizeExclusionFilter, normalizeExclusionFilters } from "../lib/exclusionFilters";
import {
  clearCompleted,
  countExcludedRecords,
  filterRecords,
  isCompletedRecord,
  shouldRequestRequestBody,
  shouldRequestResponseBody,
  sidebarPlaceholderText
} from "../lib/records";

export interface NetworkInspectorModel {
  client: NetworkClient;
  uiState: ReturnType<typeof useInspectorUiState>;
  metadata: InspectorMetadata | null;
  isConnected: boolean;
  selectedRecord: InspectorRecord | null;
  selectedRecordId: string | null;
  visibleRecords: InspectorRecord[];
  allRecords: InspectorRecord[];
  sidebarPlaceholder: string | null;
  searchText: string;
  exclusionFilters: string[];
  hiddenRequestCount: number;
  sortNewestFirst: boolean;
  totalItems: number;
  hasClearableItems: boolean;
  streamIsRetrying: boolean;
  selectRecord(id: string): void;
  addExclusionFilter(value: string): void;
  removeExclusionFilter(filter: string): void;
  retryResponseBody(): void;
}

export function useNetworkInspectorModel(
  client: NetworkClient,
  metadata: InspectorMetadata | null,
  isConnected: boolean,
  connectionRevision = 0
): NetworkInspectorModel {
  const [state, setState] = useState<InspectorDataState>(() => createEmptyInspectorState());
  const [preferredRecordId, setPreferredRecordId] = useState<string | null>(null);
  const [searchText, setSearchText] = useState("");
  const [exclusionFilters, setExclusionFilters] = useState<string[]>([]);
  const [exclusionFiltersRevision] = useState(() => new ExclusionFiltersRevision());
  const [sortNewestFirst, setSortNewestFirst] = useState(false);
  const [, setBodyCacheRevision] = useState(0);
  const [streamLifecycle, setStreamLifecycle] = useState<{
    revision: number;
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

  useEffect(() => {
    let disposed = false;
    const reload = () => {
      const revision = exclusionFiltersRevision.capture();
      void client.listExclusionFilters().then(
        (filters) => {
          if (!disposed && exclusionFiltersRevision.isCurrent(revision))
            setExclusionFilters(normalizeExclusionFilters(filters));
        },
        () => {}
      );
    };
    const changed = (event: StorageEvent) => {
      if (event.key === null || event.key === "network.exclusionFilters") {
        exclusionFiltersRevision.invalidate();
        reload();
      }
    };
    reload();
    window.addEventListener("storage", changed);
    return () => {
      disposed = true;
      window.removeEventListener("storage", changed);
    };
  }, [client, exclusionFiltersRevision]);

  useEffect(() => {
    const unsubscribeEvent = client.onEvent((event) => {
      setState((current) => reduceCdpMessage(current, event.processId, event.message));
    });
    return unsubscribeEvent;
  }, [client]);

  const streamIsRetrying = streamLifecycle?.revision === connectionRevision && streamLifecycle.state === "retrying";

  useEffect(() => {
    if (!isConnected || !metadata || metadata.protocolVersion !== supportedProtocolVersion) return;
    const controller = new NetworkStreamController(client, metadata, (state) => {
      setStreamLifecycle({ revision: connectionRevision, state });
    });
    controller.start();
    return () => controller.dispose();
  }, [client, metadata, isConnected, connectionRevision]);

  const allRecords = hydrateCachedBodies([...state.requests.values(), ...state.webSockets.values()], bodyCache);

  const visibleRecords = useMemo(
    () => filterRecords(allRecords, searchText, sortNewestFirst, exclusionFilters),
    [allRecords, exclusionFilters, searchText, sortNewestFirst]
  );

  const hiddenRequestCount = useMemo(
    () => countExcludedRecords(allRecords, exclusionFilters),
    [allRecords, exclusionFilters]
  );

  const totalItems = allRecords.length;

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
    const recordKey = requestRecordKey(selectedRecord.processId, selectedRecord.requestId);
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
    if (!isConnected) return;
    bodyLoader.forgetRecords(bodyCache.select(selectedRequestKey));
  }, [bodyCache, bodyLoader, isConnected, selectedRequestKey]);

  useEffect(() => {
    const jobs: BodyLoadJob[] = [];
    const retainedRecordKeys = new Set(state.requests.keys());
    bodyLoader.forgetRecords(bodyCache.retainRecords(retainedRecordKeys));

    if (isConnected && selectedRecord?.kind === "request") {
      const recordKey = requestRecordKey(selectedRecord.processId, selectedRecord.requestId);
      const requestAttemptKey = `${recordKey}\u0000request`;
      const responseAttemptKey = `${recordKey}\u0000response`;

      if (shouldRequestRequestBody(selectedRecord)) {
        jobs.push({
          key: requestAttemptKey,
          recordKey,
          priority: bodyLoadPriority.selected,
          input: {
            processId: selectedRecord.processId,
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
            processId: selectedRecord.processId,
            requestId: selectedRecord.requestId,
            includeRequestBody: false,
            includeResponseBody: true
          }
        });
      }
    }

    bodyLoader.retainRecords(retainedRecordKeys);
    bodyLoader.schedule(jobs);
  }, [bodyCache, bodyLoader, isConnected, selectedRecord, state.requests]);

  const sidebarPlaceholder = useMemo(
    () =>
      sidebarPlaceholderText({
        totalItems: allRecords.length,
        filteredItems: visibleRecords.length,
        streamIsRetrying
      }),
    [allRecords.length, streamIsRetrying, visibleRecords.length]
  );
  const hasClearableItems = useMemo(() => allRecords.some(isCompletedRecord), [allRecords]);
  useEffect(() => {
    void host
      .setToolbar({
        start: [
          {
            type: "button",
            id: "clear",
            icon: "clear",
            label: "Clear completed requests",
            enabled: hasClearableItems,
            onClick: clearCompletedRecords
          },
          {
            type: "button",
            id: "sort",
            icon: sortNewestFirst ? "sortDescending" : "sortAscending",
            label: sortNewestFirst ? "Show oldest first" : "Show newest first",
            onClick: () => setSortNewestFirst(!sortNewestFirst)
          },
          { type: "search", id: "search", label: "Filter requests", value: searchText, onChange: setSearchText }
        ],
        end: [
          {
            type: "button",
            id: "export",
            icon: "export",
            label: "Export HAR (sanitized)",
            enabled: visibleRecords.length > 0,
            onClick: () => {
              void exportAsHar(client, visibleRecords, undefined, isConnected);
            }
          }
        ]
      })
      .catch(() => {});
  }, [client, clearCompletedRecords, hasClearableItems, searchText, isConnected, sortNewestFirst, visibleRecords]);
  useEffect(
    () => () => {
      void host.setToolbar({ start: [] }).catch(() => {});
    },
    []
  );

  const selectRecord = useCallback((id: string) => setPreferredRecordId(id), []);

  return {
    client,
    uiState,
    metadata,
    isConnected,
    selectedRecord,
    selectedRecordId,
    visibleRecords,
    allRecords,
    sidebarPlaceholder,
    searchText,
    exclusionFilters,
    hiddenRequestCount,
    sortNewestFirst,
    totalItems,
    hasClearableItems,
    streamIsRetrying,
    selectRecord,
    addExclusionFilter,
    removeExclusionFilter,
    retryResponseBody
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
    const bodies = bodyCache.peek(requestRecordKey(record.processId, record.requestId));
    return bodies == null ? record : applyRequestBodies(record, bodies);
  });
}
