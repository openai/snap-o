import { memo } from "react";
import { recordId, type Header, type RequestRecord } from "../../../network/cdp";
import { makeBodyPayload } from "../../../network/payload";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { formatTiming } from "../lib/format";
import { BodySection, payloadMetadata } from "./PayloadView";
import { HeadersTable, Section } from "./Section";
import { FailureMessage, StatusBadge } from "./Status";
import { SseCopyAllButton, SseEventList } from "./StreamEvents";

export const RequestDetail = memo(function RequestDetail({
  record,
  uiState
}: {
  record: RequestRecord;
  uiState: InspectorUiState;
}): JSX.Element {
  const isSseResponse = isLikelySseResponse(record);
  const requestBody = makeBodyPayload({
    body: record.requestBody,
    headers: record.requestHeaders,
    encoding: record.requestBodyEncoding
  });
  const responseBody = isSseResponse
    ? null
    : makeBodyPayload({
        body: record.responseBody,
        headers: record.responseHeaders,
        base64Encoded: record.responseBodyBase64Encoded,
        totalBytes: record.encodedDataLength
      });
  const prefix = `request:${recordId(record)}`;

  return (
    <div className="detail-scroll">
      <header className="detail-header">
        <div className="title-row">
          <span className="detail-method">{record.method}</span>
          <h1>{record.url}</h1>
        </div>
        <div className="detail-meta">
          <StatusBadge record={record} />
          <span>{formatTiming(record.startedAt, record.endedAt, record.status)}</span>
        </div>
        <FailureMessage status={record.status} />
      </header>

      {record.requestHeaders.length === 0 ? null : (
        <Section
          title="Request Headers"
          storageKey={`${prefix}:requestHeaders`}
          uiState={uiState}
          initiallyExpanded={false}
        >
          <HeadersTable headers={record.requestHeaders} />
        </Section>
      )}
      {requestBody == null ? null : (
        <Section
          title="Request Body"
          meta={payloadMetadata(requestBody)}
          storageKey={`${prefix}:requestBody`}
          uiState={uiState}
          initiallyExpanded={false}
        >
          <BodySection payload={requestBody} storageKey={`${prefix}:requestBody:payload`} uiState={uiState} />
        </Section>
      )}
      {record.status.kind === "pending" ? <div className="pending-response">Waiting for response...</div> : null}
      {record.responseHeaders.length === 0 ? null : (
        <Section title="Response Headers" storageKey={`${prefix}:responseHeaders`} uiState={uiState}>
          <HeadersTable headers={record.responseHeaders} />
        </Section>
      )}
      {isSseResponse ? (
        <Section
          title="Server-Sent Events"
          storageKey={`${prefix}:stream`}
          uiState={uiState}
          trailing={<SseCopyAllButton events={record.streamEvents} />}
        >
          <SseEventList
            events={record.streamEvents}
            closed={record.streamClosed}
            storageKey={`${prefix}:stream`}
            uiState={uiState}
          />
        </Section>
      ) : null}
      {responseBody == null ? null : (
        <Section
          title="Response Body"
          meta={payloadMetadata(responseBody)}
          storageKey={`${prefix}:responseBody`}
          uiState={uiState}
        >
          <BodySection payload={responseBody} storageKey={`${prefix}:responseBody:payload`} uiState={uiState} />
        </Section>
      )}
    </div>
  );
});

function isLikelySseResponse(record: RequestRecord): boolean {
  if (record.streamEvents.length > 0) return true;
  if (record.responseType?.toLowerCase() === "eventsource") return true;
  return hasEventStreamHeader(record.responseHeaders) || hasEventStreamHeader(record.requestHeaders);
}

function hasEventStreamHeader(headers: Header[]): boolean {
  return headers.some((header) => {
    const name = header.name.toLowerCase();
    const value = header.value.toLowerCase();
    return (name === "content-type" || name === "accept") && value.includes("text/event-stream");
  });
}
