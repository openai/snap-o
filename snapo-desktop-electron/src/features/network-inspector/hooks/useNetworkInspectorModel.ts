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
  type RequestRecord,
  type ServerId
} from "../../../network/cdp";
import type { DebugInspectorPreset, SnapOServer } from "../../../network/bridge-types";
import { decodeRequestBodyForDisplay } from "../../../network/payload";
import { useInspectorUiState } from "./useInspectorUiState";
import { applyDebugInspectorPreset } from "../lib/debug";
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

interface DecodedRequestBodyKey {
  body: string;
  encoding: string | null | undefined;
  contentEncoding: string | null;
}

interface DecodedRequestBodyEntry extends DecodedRequestBodyKey {
  displayText: string;
}

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
  const decodedRequestBodyKeysRef = useRef<Map<string, DecodedRequestBodyKey>>(new Map());
  const [decodedRequestBodies, setDecodedRequestBodies] = useState<Map<string, DecodedRequestBodyEntry>>(
    () => new Map()
  );
  const [preferredRecordId, setPreferredRecordId] = useState<string | null>(null);
  const [searchText, setSearchText] = useState("");
  const [sortNewestFirst, setSortNewestFirst] = useState(false);
  const [debugPreset, setDebugPreset] = useState<DebugInspectorPreset>("live");
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
  const displayServers = useMemo(
    () => applyDebugInspectorPreset(state.servers, selectedServer, debugPreset),
    [debugPreset, selectedServer, state.servers]
  );
  const selectedServerModel = useMemo(
    () => serverModelFor(displayServers, selectedServer),
    [displayServers, selectedServer]
  );
  const selectedServerIsConnected = selectedServerModel?.isConnected === true;
  const selectedServerConnectionKey =
    selectedServerModel == null
      ? selectedServerKey
      : `${selectedServerKey}\u0000${selectedServerModel.isConnected}\u0000${selectedServerModel.hasAppInfo}`;

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

  useEffect(() => {
    const activeDecodedKeys = new Set<string>();

    for (const request of state.requests.values()) {
      if (request.requestBody == null || !shouldDecodeRequestBodyForSearch(request)) continue;

      const recordKey = requestRecordKey(request.server, request.requestId);
      activeDecodedKeys.add(recordKey);
      const decodeKey = {
        body: request.requestBody,
        encoding: request.requestBodyEncoding,
        contentEncoding: requestHeaderValue(request.requestHeaders, "content-encoding")
      };

      if (decodedRequestBodyKeyEquals(decodedRequestBodyKeysRef.current.get(recordKey), decodeKey)) continue;

      decodedRequestBodyKeysRef.current.set(recordKey, decodeKey);
      void decodeRequestBodyForDisplay({
        body: request.requestBody,
        headers: request.requestHeaders,
        encoding: request.requestBodyEncoding
      }).then((displayText) => {
        if (!decodedRequestBodyKeyEquals(decodedRequestBodyKeysRef.current.get(recordKey), decodeKey)) return;
        setDecodedRequestBodies((current) => {
          if (current.get(recordKey)?.displayText === displayText) return current;
          const next = new Map(current);
          next.set(recordKey, { ...decodeKey, displayText });
          return next;
        });
      });
    }

    for (const recordKey of decodedRequestBodyKeysRef.current.keys()) {
      if (activeDecodedKeys.has(recordKey)) continue;
      decodedRequestBodyKeysRef.current.delete(recordKey);
    }
  }, [state.requests]);

  const requestBodyDisplayTextByRecordKey = useMemo(() => {
    const displayTextByRecordKey = new Map<string, string>();
    for (const request of state.requests.values()) {
      if (request.requestBody == null || !shouldDecodeRequestBodyForSearch(request)) continue;
      const recordKey = requestRecordKey(request.server, request.requestId);
      const decodeKey = {
        body: request.requestBody,
        encoding: request.requestBodyEncoding,
        contentEncoding: requestHeaderValue(request.requestHeaders, "content-encoding")
      };
      const decoded = decodedRequestBodies.get(recordKey);
      if (decoded != null && decodedRequestBodyKeyEquals(decoded, decodeKey)) {
        displayTextByRecordKey.set(recordKey, decoded.displayText);
      }
    }
    return displayTextByRecordKey;
  }, [decodedRequestBodies, state.requests]);

  const visibleRecords = useMemo(
    () => filterRecords(allRecords, selectedServer, searchText, sortNewestFirst, requestBodyDisplayTextByRecordKey),
    [allRecords, requestBodyDisplayTextByRecordKey, searchText, selectedServer, sortNewestFirst]
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
    () => replacementCandidate(displayServers, selectedServerModel),
    [displayServers, selectedServerModel]
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
  const clearCompletedRecords = useCallback(() => {
    decodedRequestBodyKeysRef.current.clear();
    setDecodedRequestBodies(new Map());
    setState(clearCompleted);
  }, []);
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

function shouldDecodeRequestBodyForSearch(request: RequestRecord): boolean {
  return (
    request.requestBodyEncoding?.toLowerCase() === "base64" &&
    hasGzipContentEncoding(requestHeaderValue(request.requestHeaders, "content-encoding"))
  );
}

function requestHeaderValue(headers: RequestRecord["requestHeaders"], name: string): string | null {
  return headers.find((header) => header.name.toLowerCase() === name)?.value ?? null;
}

function hasGzipContentEncoding(value: string | null): boolean {
  if (value == null || value.trim().length === 0) return false;
  return value
    .split(/[,\n]/u)
    .map((token) => token.split(";")[0].trim().toLowerCase())
    .includes("gzip");
}

function decodedRequestBodyKeyEquals(left: DecodedRequestBodyKey | undefined, right: DecodedRequestBodyKey): boolean {
  return (
    left != null &&
    left.body === right.body &&
    left.encoding === right.encoding &&
    left.contentEncoding === right.contentEncoding
  );
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
    left.protocolVersion === right.protocolVersion &&
    left.isProtocolNewerThanSupported === right.isProtocolNewerThanSupported &&
    left.isProtocolOlderThanSupported === right.isProtocolOlderThanSupported &&
    left.packageName === right.packageName &&
    left.appName === right.appName
  );
}
