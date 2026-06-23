import type { NetworkClient } from "../../../network/client";
import { applyRequestBodies, type InspectorRecord, type RequestRecord } from "../../../network/cdp";
import { buildHar, harFileName, makeCurlCommand } from "../../../network/exporters";

export async function copyCurl(client: NetworkClient, request: RequestRecord): Promise<void> {
  let hydrated = request;
  if (request.requestBody == null) {
    try {
      hydrated = applyRequestBodies(
        request,
        await client.loadBodies({
          deviceId: request.server.deviceId,
          socketName: request.server.socketName,
          requestId: request.requestId
        })
      );
    } catch {
      hydrated = request;
    }
  }
  await client.copyText(makeCurlCommand(hydrated));
}

export async function exportAsHar(client: NetworkClient, records: InspectorRecord[]): Promise<void> {
  if (records.length === 0) return;
  const hydrated = await Promise.all(
    records.map(async (record) => {
      if (record.kind !== "request" || (record.requestBody != null && record.responseBody != null)) return record;
      try {
        const bodies = await client.loadBodies({
          deviceId: record.server.deviceId,
          socketName: record.server.socketName,
          requestId: record.requestId
        });
        return applyRequestBodies(record, bodies);
      } catch {
        return record;
      }
    })
  );
  const appVersion = await client.appVersion();
  await client.saveFile({
    defaultPath: harFileName(hydrated.length),
    data: buildHar(hydrated, appVersion),
    mimeType: "application/har+json",
    directoryKind: "har"
  });
}
