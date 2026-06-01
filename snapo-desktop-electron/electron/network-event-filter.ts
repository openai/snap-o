import type { CdpMessage } from "../src/network/bridge-types.js";
import { matchesUrlFilterText } from "../src/network/url-filter.js";

export class NetworkEventFilter {
  private readonly matchingRequestIds = new Set<string>();

  constructor(private readonly searchText: string) {}

  matches(message: CdpMessage): boolean {
    if (this.searchText.trim().length === 0) return true;

    const requestId = stringAt(message.params, "requestId");
    const url = eventUrl(message);
    if (url != null && matchesUrlFilterText(url, this.searchText)) {
      if (requestId != null) this.matchingRequestIds.add(requestId);
      return true;
    }
    return requestId != null && this.matchingRequestIds.has(requestId);
  }
}

function eventUrl(message: CdpMessage): string | null {
  switch (message.method) {
    case "Network.requestWillBeSent":
      return stringAt(message.params, "request.url");
    case "Network.responseReceived":
      return stringAt(message.params, "response.url");
    case "Network.webSocketCreated":
      return stringAt(message.params, "url");
    default:
      return null;
  }
}

function stringAt(root: Record<string, unknown> | undefined, path: string): string | null {
  let current: unknown = root;
  for (const segment of path.split(".")) {
    if (!isRecord(current)) return null;
    current = current[segment];
  }
  return typeof current === "string" ? current : null;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value != null && !Array.isArray(value);
}
