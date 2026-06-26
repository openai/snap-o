import type { NetworkClient } from "../../../network/client";
import type { RequestBodies } from "../../../network/bridge-types";
import { estimatedStringStorageBytes, hydratedBodyRetentionLimitBytes } from "../../../network/body-retention";
import { applyRequestBodies, type InspectorRecord, type RequestRecord } from "../../../network/cdp";
import { buildHar, harFileName, makeCurlCommand, streamEventsRaw } from "../../../network/exporters";
import { shouldRequestRequestBody } from "./records";

const exportBodyLoadConcurrency = 3;

export async function copyCurl(client: NetworkClient, request: RequestRecord): Promise<void> {
  let hydrated = request;
  if (shouldRequestRequestBody(request)) {
    try {
      hydrated = applyRequestBodies(
        request,
        await client.loadBodies({
          deviceId: request.server.deviceId,
          socketName: request.server.socketName,
          serverInstanceId: request.server.instanceId,
          requestId: request.requestId
        })
      );
    } catch {
      hydrated = request;
    }
  }
  await client.copyText(makeCurlCommand(hydrated));
}

export async function exportAsHar(
  client: NetworkClient,
  records: InspectorRecord[],
  maximumBodyBytes = hydratedBodyRetentionLimitBytes
): Promise<void> {
  if (records.length === 0) return;
  const hydrated = await hydrateRecordsForHar(client, records, maximumBodyBytes);
  const appVersion = await client.appVersion();
  await client.saveFile({
    defaultPath: harFileName(hydrated.length),
    data: buildHar(hydrated, appVersion),
    mimeType: "application/har+json",
    directoryKind: "har"
  });
}

export async function hydrateRecordsForHar(
  client: Pick<NetworkClient, "loadBodies">,
  records: InspectorRecord[],
  maximumBodyBytes = hydratedBodyRetentionLimitBytes
): Promise<InspectorRecord[]> {
  if (!Number.isSafeInteger(maximumBodyBytes) || maximumBodyBytes < 0) {
    throw new Error("HAR body budget must be a non-negative integer");
  }

  let retainedBodyBytes = 0;
  const omittedRecordIndexes = new Set<number>();
  const hydrated = records.map((record, index) => {
    const recordBodyBytes = harBodyTextBytes(record);
    if (retainedBodyBytes + recordBodyBytes <= maximumBodyBytes) {
      retainedBodyBytes += recordBodyBytes;
      return record;
    }
    omittedRecordIndexes.add(index);
    return omittingHarBodyText(record);
  });

  const hydrationIndexes = hydrated.flatMap((record, index) => {
    if (
      omittedRecordIndexes.has(index) ||
      record.kind !== "request" ||
      (record.requestBody != null && record.responseBody != null)
    ) {
      return [];
    }
    return [index];
  });

  let canHydrateMissingBodies = retainedBodyBytes < maximumBodyBytes;
  for (
    let offset = 0;
    offset < hydrationIndexes.length && canHydrateMissingBodies;
    offset += exportBodyLoadConcurrency
  ) {
    const batchIndexes = hydrationIndexes.slice(offset, offset + exportBodyLoadConcurrency);
    const batch = await Promise.all(
      batchIndexes.map(async (index) => ({ index, bodies: await loadBodiesForHar(client, hydrated[index]) }))
    );
    for (const { index, bodies } of batch) {
      if (bodies == null) continue;
      const record = hydrated[index];
      if (record.kind !== "request") continue;
      const candidate = applyRequestBodies(record, bodies);
      const candidateTotalBytes = retainedBodyBytes - harBodyTextBytes(record) + harBodyTextBytes(candidate);
      if (candidateTotalBytes > maximumBodyBytes) {
        canHydrateMissingBodies = false;
        break;
      }
      hydrated[index] = candidate;
      retainedBodyBytes = candidateTotalBytes;
      canHydrateMissingBodies = retainedBodyBytes < maximumBodyBytes;
      if (!canHydrateMissingBodies) break;
    }
  }
  return hydrated;
}

async function loadBodiesForHar(
  client: Pick<NetworkClient, "loadBodies">,
  record: InspectorRecord
): Promise<RequestBodies | null> {
  if (record.kind !== "request") return null;
  try {
    return await client.loadBodies({
      deviceId: record.server.deviceId,
      socketName: record.server.socketName,
      serverInstanceId: record.server.instanceId,
      requestId: record.requestId
    });
  } catch {
    // A completed request may no longer expose its body. Keep its metadata in the HAR.
    return null;
  }
}

function harBodyTextBytes(record: InspectorRecord): number {
  if (record.kind === "websocket") {
    return record.messages.reduce((total, message) => total + estimatedStringStorageBytes(message.preview), 0);
  }
  const responseText =
    record.responseBody ?? (record.streamEvents.length > 0 ? streamEventsRaw(record.streamEvents) : null);
  return estimatedStringStorageBytes(record.requestBody) + estimatedStringStorageBytes(responseText);
}

function omittingHarBodyText(record: InspectorRecord): InspectorRecord {
  if (record.kind === "websocket") {
    return {
      ...record,
      messages: record.messages.map((message) => ({ ...message, preview: undefined }))
    };
  }
  return {
    ...record,
    requestBody: undefined,
    responseBody: undefined,
    responseBodyBase64Encoded: undefined,
    streamEvents: []
  };
}
