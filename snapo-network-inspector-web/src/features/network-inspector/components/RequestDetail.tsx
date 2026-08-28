import { memo, useEffect, useState } from "react";
import { LoadingSpinner } from "../../../components/LoadingSpinner";
import type { NetworkClient } from "../../../network/client";
import { recordId, type Header, type RequestRecord } from "../../../network/cdp";
import { decodeRequestBodyForDisplay, makeBodyPayload } from "../../../network/payload";
import { isLikelyStreamingRequest } from "../../../network/request-classification";
import type { InspectorUiState } from "../hooks/useInspectorUiState";
import { useAdaptiveTimingText } from "../hooks/useAdaptiveTimingText";
import { responseBodyCaptureMetadata, shouldRequestResponseBody } from "../lib/records";
import { BodySection, payloadMetadata } from "./PayloadView";
import { HeadersTable, Section } from "./Section";
import { FailureMessage, StatusBadge } from "./Status";
import { SseCopyAllButton, SseEventList, type SseStatus } from "./StreamEvents";

export const RequestDetail = memo(function RequestDetail({
  client,
  record,
  uiState,
  isConnected = true,
  onRetryResponseBody
}: {
  client: NetworkClient;
  record: RequestRecord;
  uiState: InspectorUiState;
  isConnected?: boolean;
  onRetryResponseBody(): void;
}): JSX.Element {
  const isSseResponse = isLikelyStreamingRequest(record);
  const streamStatus = sseStatus(record, isConnected);
  const streamClosedWithError =
    isSseResponse && record.streamClosed != null && record.streamClosed.reason !== "completed";
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
  const isResponseBodyLoading = !isSseResponse && shouldRequestResponseBody(record);
  const responseBodyLoadError = !isSseResponse && responseBody == null ? record.responseBodyLoadError : null;
  const responseBodyIsOffline =
    !isConnected && responseBody == null && (isResponseBodyLoading || responseBodyLoadError === "failed");
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
        {streamClosedWithError ? null : <FailureMessage status={record.status} />}
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
          <BodySection
            client={client}
            payload={requestBody}
            storageKey={`${prefix}:requestBody:payload`}
            uiState={uiState}
          />
        </Section>
      )}
      {!isSseResponse && isConnected && record.status.kind === "pending" && !record.hasReceivedResponse ? (
        <div className="pending-response">Waiting for response</div>
      ) : null}
      {record.responseHeaders.length === 0 ? null : (
        <Section title="Response Headers" storageKey={`${prefix}:responseHeaders`} uiState={uiState}>
          <HeadersTable headers={record.responseHeaders} />
        </Section>
      )}
      {isSseResponse ? (
        <Section
          title={
            <>
              Server-Sent Events
              <span className="section-status">· {streamStatus}</span>
            </>
          }
          storageKey={`${prefix}:stream`}
          uiState={uiState}
          trailing={<SseCopyAllButton client={client} events={record.streamEvents} />}
        >
          <SseEventList
            client={client}
            events={record.streamEvents}
            closed={record.streamClosed}
            status={streamStatus}
            storageKey={`${prefix}:stream`}
            uiState={uiState}
          />
        </Section>
      ) : null}
      {responseBody == null && !isResponseBodyLoading && responseBodyLoadError == null ? null : (
        <Section
          title="Response Body"
          meta={
            responseBodyLoadError != null
              ? null
              : responseBody == null
                ? responseBodyCaptureMetadata(record)
                : payloadMetadata(responseBody)
          }
          storageKey={`${prefix}:responseBody`}
          uiState={uiState}
        >
          {responseBodyIsOffline ? (
            <div className="body-load-message" role="status">
              Response body isn’t cached on this Mac.
            </div>
          ) : responseBodyLoadError != null ? (
            <div className="body-load-message" role="status">
              <span>
                {responseBodyLoadError === "unavailable"
                  ? "This response is no longer available. Try making the request again."
                  : "Couldn’t load the response. Try again."}
              </span>
              {responseBodyLoadError === "failed" ? (
                <button className="text-button" type="button" onClick={onRetryResponseBody}>
                  Retry
                </button>
              ) : null}
            </div>
          ) : responseBody == null ? (
            <div className="payload-card">
              <div className="body-loading" role="status">
                <LoadingSpinner size={14} />
                <span>Loading</span>
              </div>
            </div>
          ) : (
            <BodySection
              client={client}
              payload={responseBody}
              storageKey={`${prefix}:responseBody:payload`}
              uiState={uiState}
            />
          )}
        </Section>
      )}
    </div>
  );
});

function sseStatus(record: RequestRecord, isConnected: boolean): SseStatus {
  if (record.streamClosed != null) return "Closed";
  if (!isConnected) return "Offline";
  if (record.hasReceivedResponse || record.streamEvents.length > 0) return "Streaming";
  return "Pending";
}

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
