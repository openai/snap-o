interface Header {
  name: string;
  value: string;
}

interface StreamingRequestEvidence {
  requestHeaders: Header[];
  responseHeaders: Header[];
  responseType?: string | null;
  hasReceivedResponse?: boolean;
  streamEvents: unknown[];
}

export function isLikelyStreamingRequest(request: StreamingRequestEvidence): boolean {
  if (request.streamEvents.length > 0) return true;
  if (request.responseType?.toLowerCase() === "eventsource") return true;
  if (request.hasReceivedResponse === true) return hasEventStreamContentType(request.responseHeaders);
  return hasEventStreamContentType(request.responseHeaders) || acceptsEventStream(request.requestHeaders);
}

function hasEventStreamContentType(headers: Header[]): boolean {
  return headers.some((header) => {
    return header.name.toLowerCase() === "content-type" && header.value.toLowerCase().includes("text/event-stream");
  });
}

function acceptsEventStream(headers: Header[]): boolean {
  return headers.some((header) => {
    return header.name.toLowerCase() === "accept" && header.value.toLowerCase().includes("text/event-stream");
  });
}
