import type { JSX } from "preact";
import type { ToolContentClient } from "../../../network/client";
import { recordId, type RequestRecord } from "../../../network/cdp";
import { makeBodyPayload, type BodyPayload } from "../../../network/payload";
import type { ToolUiState } from "../hooks/useToolUiState";
import { statusDisplayName } from "../lib/format";
import {
  responseBodyCaptureMetadata,
  responseHasNoBody,
  shouldRequestOriginalResponseBody,
  shouldRequestResponseBody
} from "../lib/records";
import { payloadMetadata } from "./PayloadView";
import { HeadersTable, Section } from "./Section";
import { ResponseBodyContent } from "./ResponseBodyContent";

export function InterceptedResponses({
  client,
  record,
  uiState,
  isConnected,
  deliveredBody,
  deliveredStream,
  onRetryDeliveredBody,
  onRetryOriginalResponseBody
}: {
  client: ToolContentClient;
  record: RequestRecord;
  uiState: ToolUiState;
  isConnected: boolean;
  deliveredBody: BodyPayload | null;
  deliveredStream: JSX.Element | null;
  onRetryDeliveredBody(): void;
  onRetryOriginalResponseBody?(): void;
}): JSX.Element {
  const prefix = `request:${recordId(record)}`;

  const deliveredStatus = record.status.kind === "success" ? record.status.code : null;
  const deliveredHeaders = record.responseHeaders;
  const deliveredError = record.responseBodyLoadError;
  const awaitingDeliveredBody =
    record.endedAt == null &&
    deliveredStatus != null &&
    record.encodedDataLength !== 0 &&
    !responseHasNoBody(record.method, deliveredStatus, deliveredHeaders);
  const deliveredLoading = awaitingDeliveredBody || shouldRequestResponseBody(record);
  const deliveredMeta = responseMeta(deliveredStatus, deliveredBody, deliveredError, record);

  const originalResponse = record.interception?.originalResponse;
  const originalBody = originalResponse
    ? makeBodyPayload({
        body: record.originalResponseBody,
        headers: originalResponse.headers,
        encoding: originalResponse.bodyEncoding,
        base64Encoded: record.originalResponseBodyBase64Encoded,
        totalBytes: originalResponse.encodedDataLength
      })
    : null;
  const originalError = record.originalResponseBodyLoadError;
  const originalLoading = shouldRequestOriginalResponseBody(record);
  const originalMeta = originalResponse
    ? responseMeta(originalResponse.status, originalBody, originalError, {
        encodedDataLength: originalResponse.encodedDataLength ?? undefined,
        responseBodyTruncatedBytes: originalResponse.bodyTruncatedBytes
      })
    : null;

  return (
    <>
      <Section
        title="Response (overwritten)"
        meta={deliveredMeta}
        storageKey={`${prefix}:overwrittenResponse`}
        uiState={uiState}
      >
        <HeadersTable headers={deliveredHeaders} />
        {deliveredStream ?? (
          <ResponseBodyContent
            client={client}
            payload={deliveredBody}
            loading={deliveredLoading}
            error={deliveredError}
            isConnected={isConnected}
            storageKey={`${prefix}:responseBody:payload`}
            uiState={uiState}
            onRetry={onRetryDeliveredBody}
          />
        )}
      </Section>
      <Section
        title="Original Response"
        meta={originalMeta}
        storageKey={`${prefix}:originalResponse`}
        uiState={uiState}
        initiallyExpanded={false}
      >
        {originalResponse == null ? (
          <div className="body-load-message">
            {record.interception?.outcome === "mocked"
              ? "No upstream call was made."
              : "The original response was not captured."}
          </div>
        ) : (
          <>
            <HeadersTable headers={originalResponse.headers} />
            <ResponseBodyContent
              client={client}
              payload={originalBody}
              loading={originalLoading}
              error={originalError}
              isConnected={isConnected}
              storageKey={`${prefix}:originalResponse:payload`}
              uiState={uiState}
              onRetry={onRetryOriginalResponseBody}
            />
          </>
        )}
      </Section>
    </>
  );
}

function responseMeta(
  status: number | null,
  body: BodyPayload | null,
  error: RequestRecord["responseBodyLoadError"],
  capture: Pick<RequestRecord, "encodedDataLength" | "responseBodyTruncatedBytes">
): string {
  let size: string | null = null;
  if (error == null) size = body == null ? responseBodyCaptureMetadata(capture) : payloadMetadata(body);
  return [status == null ? null : statusDisplayName(status), size].filter(Boolean).join(" · ");
}
