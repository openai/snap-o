import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { createNetworkClient, type NetworkClient } from "../../../network/client";
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
import type { SnapOServer } from "../../../network/bridge-types";
import { useInspectorUiState } from "./useInspectorUiState";
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

const docsUrl = "https://github.com/openai/snap-o/blob/main/docs/network-inspector.md";

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
  sortNewestFirst: boolean;
  serverRecordCount: number;
  hasClearableItems: boolean;
  selectServer(server: ServerId | null): void;
  selectReplacementServer(server: SnapOServer): void;
  selectRecord(id: string): void;
  setSearchText(value: string): void;
  toggleSortOrder(): void;
  clearCompletedRecords(): void;
  openDocs(): void;
}

export function useNetworkInspectorModel(): NetworkInspectorModel {
  const client = useMemo(() => createNetworkClient(), []);
  const [state, setState] = useState<InspectorDataState>(() => createEmptyInspectorState());
  const [preferredServer, setPreferredServer] = useState<ServerId | null>(null);
  const selectedServerRef = useRef<ServerId | null>(null);
  const bodyLoadAttemptsRef = useRef<Set<string>>(new Set());
  const [preferredRecordId, setPreferredRecordId] = useState<string | null>(null);
  const [searchText, setSearchText] = useState("");
  const [sortNewestFirst, setSortNewestFirst] = useState(false);
  const uiState = useInspectorUiState();

  const selectedServer = useMemo(
    () => pickSelectedServer(preferredServer, state.servers),
    [preferredServer, state.servers]
  );

  useEffect(() => {
    selectedServerRef.current = selectedServer;
  }, [selectedServer]);

  useEffect(() => {
    const unsubscribeEvent = client.onEvent((event) => {
      setState((current) => reduceCdpMessage(current, event.server, event.message));
    });
    return unsubscribeEvent;
  }, [client]);

  useEffect(() => {
    let disposed = false;
    const refresh = async () => {
      const activeServers = await client.listServers();
      if (disposed) return;

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
  }, [client]);

  const selectedServerKey = serverKey(selectedServer);
  const selectedServerModel = useMemo(
    () => serverModelFor(state.servers, selectedServer),
    [selectedServer, state.servers]
  );
  const selectedServerIsConnected = selectedServerModel?.isConnected === true;
  const selectedServerConnectionKey =
    selectedServerModel == null
      ? selectedServerKey
      : `${selectedServerKey}\u0000${selectedServerModel.isConnected}\u0000${selectedServerModel.hasHello}`;

  useEffect(() => {
    if (selectedServer == null || !selectedServerIsConnected) return;
    let streamId: string | null = null;
    let disposed = false;
    client
      .startStream(selectedServer)
      .then((started) => {
        if (disposed) {
          void client.stopStream(started.streamId);
          return;
        }
        streamId = started.streamId;
      })
      .catch(() => {
        // The Compose app keeps the pane chrome quiet; connection failures surface as empty states.
      });

    return () => {
      disposed = true;
      if (streamId != null) void client.stopStream(streamId);
    };
  }, [client, selectedServer, selectedServerConnectionKey, selectedServerIsConnected]);

  const allRecords = useMemo(
    () => [...state.requests.values(), ...state.webSockets.values()],
    [state.requests, state.webSockets]
  );

  const visibleRecords = useMemo(
    () => filterRecords(allRecords, selectedServer, searchText, sortNewestFirst),
    [allRecords, searchText, selectedServer, sortNewestFirst]
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

  useEffect(() => {
    const loads: Array<{
      recordKey: string;
      deviceId: string;
      socketName: string;
      requestId: string;
      includeRequestBody: boolean;
      includeResponseBody: boolean;
    }> = [];

    for (const request of state.requests.values()) {
      const recordKey = requestRecordKey(request.server, request.requestId);
      const requestAttemptKey = `${recordKey}\u0000request`;
      const responseAttemptKey = `${recordKey}\u0000response`;

      if (shouldRequestRequestBody(request) && !bodyLoadAttemptsRef.current.has(requestAttemptKey)) {
        bodyLoadAttemptsRef.current.add(requestAttemptKey);
        loads.push({
          recordKey,
          deviceId: request.server.deviceId,
          socketName: request.server.socketName,
          requestId: request.requestId,
          includeRequestBody: true,
          includeResponseBody: false
        });
      }

      if (shouldRequestResponseBody(request) && !bodyLoadAttemptsRef.current.has(responseAttemptKey)) {
        bodyLoadAttemptsRef.current.add(responseAttemptKey);
        loads.push({
          recordKey,
          deviceId: request.server.deviceId,
          socketName: request.server.socketName,
          requestId: request.requestId,
          includeRequestBody: false,
          includeResponseBody: true
        });
      }
    }

    if (loads.length === 0) return;
    for (const load of loads) {
      client
        .loadBodies({
          deviceId: load.deviceId,
          socketName: load.socketName,
          requestId: load.requestId,
          includeRequestBody: load.includeRequestBody,
          includeResponseBody: load.includeResponseBody
        })
        .then((bodies) => {
          setState((current) => {
            const currentRecord = current.requests.get(load.recordKey);
            if (currentRecord == null) return current;
            const requests = new Map(current.requests);
            requests.set(load.recordKey, applyRequestBodies(currentRecord, bodies));
            return { ...current, requests };
          });
        })
        .catch(() => {
          // Some requests legitimately have no body or cannot be read after completion.
        });
    }
  }, [client, state.requests]);

  const replacementServer = useMemo(
    () => replacementCandidate(state.servers, selectedServerModel),
    [selectedServerModel, state.servers]
  );
  const sidebarPlaceholder = useMemo(
    () =>
      sidebarPlaceholderText({
        totalItems: allRecords.length,
        serverScopedItems: serverRecordCount,
        filteredItems: visibleRecords.length,
        selectedServer: selectedServerModel
      }),
    [allRecords.length, selectedServerModel, serverRecordCount, visibleRecords.length]
  );
  const hasClearableItems = useMemo(() => allRecords.some(isCompletedRecord), [allRecords]);

  const selectServer = useCallback((server: ServerId | null) => {
    setPreferredServer(server);
    setPreferredRecordId(null);
  }, []);
  const selectReplacementServer = useCallback(
    (server: SnapOServer) => selectServer({ deviceId: server.deviceId, socketName: server.socketName }),
    [selectServer]
  );
  const selectRecord = useCallback((id: string) => setPreferredRecordId(id), []);
  const toggleSortOrder = useCallback(() => setSortNewestFirst((value) => !value), []);
  const clearCompletedRecords = useCallback(() => setState(clearCompleted), []);
  const openDocs = useCallback(() => void client.openExternal(docsUrl), [client]);

  return {
    client,
    uiState,
    servers: state.servers,
    selectedServer: selectedServerModel,
    selectedRecord,
    selectedRecordId,
    replacementServer,
    visibleRecords,
    allRecords,
    sidebarPlaceholder,
    searchText,
    sortNewestFirst,
    serverRecordCount,
    hasClearableItems,
    selectServer,
    selectReplacementServer,
    selectRecord,
    setSearchText,
    toggleSortOrder,
    clearCompletedRecords,
    openDocs
  };
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
    left.hasHello === right.hasHello &&
    left.pid === right.pid &&
    left.schemaVersion === right.schemaVersion &&
    left.isSchemaNewerThanSupported === right.isSchemaNewerThanSupported &&
    left.isSchemaOlderThanSupported === right.isSchemaOlderThanSupported &&
    left.packageName === right.packageName &&
    left.appName === right.appName &&
    areStringArraysEqual(left.features, right.features)
  );
}

function areStringArraysEqual(left: string[], right: string[]): boolean {
  if (left.length !== right.length) return false;
  return left.every((value, index) => value === right[index]);
}
