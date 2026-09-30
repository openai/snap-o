import type { RequestRecord } from "./cdp";

export type BodyCoverage = "absent" | "incomplete" | "complete" | "unavailable";

export function requestBodyCoverage(record: RequestRecord): BodyCoverage {
  if (record.requestBody != null) return record.requestBodyTruncatedBytes === 0 ? "complete" : "incomplete";
  if (record.requestHasPostData === false || record.requestBodySize === 0) return "absent";
  return record.endedAt == null ? "incomplete" : "unavailable";
}

export function responseBodyCoverage(record: RequestRecord): BodyCoverage {
  if (record.responseBody != null) {
    return record.endedAt != null && record.status.kind !== "failure" && (record.responseBodyTruncatedBytes ?? 0) === 0
      ? "complete"
      : "incomplete";
  }
  if (
    record.method === "HEAD" ||
    record.encodedDataLength === 0 ||
    (record.status.kind === "success" && [204, 304].includes(record.status.code)) ||
    (record.status.kind === "failure" && !record.hasReceivedResponse)
  )
    return "absent";
  return record.endedAt == null ? "incomplete" : "unavailable";
}
