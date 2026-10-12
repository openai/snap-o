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
  responseBody,
  responseStream,
  onRetryResponseBody,
  onRetryOriginalResponseBody
}: {
  client: ToolContentClient;
  record: RequestRecord;
  uiState: ToolUiState;
  isConnected: boolean;
  responseBody: BodyPayload | null;
  responseStream: JSX.Element | null;
  onRetryResponseBody(): void;
  onRetryOriginalResponseBody?(): void;
}): JSX.Element {
  const original = record.interception?.originalResponse;
  const prefix = `request:${recordId(record)}`;
  const originalBody =
    original == null
      ? null
      : makeBodyPayload({
          body: record.originalResponseBody,
          headers: original.headers,
          encoding: original.bodyEncoding,
          base64Encoded: record.originalResponseBodyBase64Encoded,
          totalBytes: original.encodedDataLength
        });
  const awaitingDeliveredBody =
    record.endedAt == null &&
    record.status.kind === "success" &&
    record.encodedDataLength !== 0 &&
    !responseHasNoBody(record.method, record.status.code, record.responseHeaders);
  const originalSize =
    record.originalResponseBodyLoadError != null
      ? null
      : originalBody != null
        ? payloadMetadata(originalBody)
        : responseBodyCaptureMetadata({
            encodedDataLength: original?.encodedDataLength ?? undefined,
            responseBodyTruncatedBytes: original?.bodyTruncatedBytes
          });
  const deliveredSize =
    record.responseBodyLoadError != null
      ? null
      : responseBody != null
        ? payloadMetadata(responseBody)
        : responseBodyCaptureMetadata(record);

  return (
    <>
      <Section
        title="Response"
        meta={original == null ? null : [statusDisplayName(original.status), originalSize].filter(Boolean).join(" · ")}
        storageKey={`${prefix}:originalResponse`}
        uiState={uiState}
      >
        {original == null ? (
          <div className="body-load-message">
            {record.interception?.outcome === "mocked"
              ? "No upstream call was made."
              : "The original response was not captured."}
          </div>
        ) : (
          <>
            <HeadersTable headers={original.headers} />
            <ResponseBodyContent
              client={client}
              payload={originalBody}
              loading={shouldRequestOriginalResponseBody(record)}
              error={record.originalResponseBodyLoadError}
              isConnected={isConnected}
              storageKey={`${prefix}:originalResponse:payload`}
              uiState={uiState}
              onRetry={onRetryOriginalResponseBody}
            />
          </>
        )}
      </Section>
      <Section
        title="Overwritten response"
        meta={[record.status.kind === "success" ? statusDisplayName(record.status.code) : null, deliveredSize]
          .filter(Boolean)
          .join(" · ")}
        storageKey={`${prefix}:overwrittenResponse`}
        uiState={uiState}
      >
        <HeadersTable headers={record.responseHeaders} />
        {responseStream ?? (
          <ResponseBodyContent
            client={client}
            payload={responseBody}
            loading={awaitingDeliveredBody || shouldRequestResponseBody(record)}
            error={record.responseBodyLoadError}
            isConnected={isConnected}
            storageKey={`${prefix}:responseBody:payload`}
            uiState={uiState}
            onRetry={onRetryResponseBody}
          />
        )}
      </Section>
    </>
  );
}
