import { memo, useEffect, useState } from "react";
import { recordId, type Header, type RequestRecord } from "../../../network/cdp";
import { decodeRequestBodyForDisplay, makeBodyPayload } from "../../../network/payload";
import { isLikelyStreamingRequest } from "../../../network/request-classification";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { useAdaptiveTimingText } from "../hooks/useAdaptiveTimingText";
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
  const isSseResponse = isLikelyStreamingRequest(record);
  const requestBodyDisplayText = useRequestBodyDisplayText(record);
  const requestBody = makeBodyPayload({
    body: record.requestBody,
    displayText: requestBodyDisplayText,
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
  const timingText = useAdaptiveTimingText(record.startedAt, record.endedAt, record.status);

  return (
    <div className="detail-scroll">
      <header className="detail-header">
        <div className="title-row">
          <span className="detail-method">{record.method}</span>
          <h1>{record.url}</h1>
        </div>
        <div className="detail-meta">
          <StatusBadge record={record} />
          <span>{timingText}</span>
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

function useRequestBodyDisplayText(record: RequestRecord): string | null {
  const contentEncoding = requestHeaderValue(record.requestHeaders, "content-encoding");
  const [decodedBody, setDecodedBody] = useState<{
    body: string;
    encoding: string | null | undefined;
    contentEncoding: string | null;
    displayText: string;
  } | null>(null);

  useEffect(() => {
    const body = record.requestBody;
    if (body == null) return;

    let disposed = false;
    void decodeRequestBodyForDisplay({
      body,
      headers: record.requestHeaders,
      encoding: record.requestBodyEncoding
    }).then((decoded) => {
      if (!disposed) {
        setDecodedBody({
          body,
          encoding: record.requestBodyEncoding,
          contentEncoding,
          displayText: decoded
        });
      }
    });

    return () => {
      disposed = true;
    };
  }, [contentEncoding, record.requestBody, record.requestBodyEncoding, record.requestHeaders]);

  if (record.requestBody == null) return null;
  if (
    decodedBody?.body === record.requestBody &&
    decodedBody.encoding === record.requestBodyEncoding &&
    decodedBody.contentEncoding === contentEncoding
  ) {
    return decodedBody.displayText;
  }
  return record.requestBody;
}

function requestHeaderValue(headers: Header[], name: string): string | null {
  return headers.find((header) => header.name.toLowerCase() === name)?.value ?? null;
}
