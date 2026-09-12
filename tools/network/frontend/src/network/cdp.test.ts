/// <reference types="vite/client" />

import { describe, expect, it } from "vitest";
import replayFixture from "../../../../../contracts/network/v2/history.jsonl?raw";
import {
  createEmptyToolState,
  enforceToolRetention,
  toolRetentionLimits,
  reduceCdpMessage,
  requestRecordKey,
  webSocketRecordKey,
  type ToolDataState
} from "./cdp";
import type { CdpMessage } from "./bridge-types";

const processId = "process-1";

describe("reduceCdpMessage", () => {
  it("uses monotonic protocol time from the shared replay contract", () => {
    let state = createEmptyToolState();
    for (const message of readReplayFixture()) {
      state = reduce(state, message, 9_000_000_000_000);
    }

    const request = state.requests.get(requestRecordKey(processId, "request-1"));
    expect(request?.startedAt).toBe(1_710_000_000_000);
    expect(request?.endedAt).toBe(1_710_000_000_250);
    expect(request?.updatedAt).toBe(1_710_000_000_250);
  });

  it("retains response truncation metadata from loading-finished events", () => {
    let state = reduce(createEmptyToolState(), requestStarted("large-response", 1));
    state = reduce(state, {
      snapoSequence: 2,
      method: "Network.responseReceived",
      params: {
        requestId: "large-response",
        timestamp: 1.1,
        type: "XHR",
        response: { url: "https://example.com/large-response", status: 200, headers: {}, encodedDataLength: 9_437_184 }
      }
    });
    state = reduce(state, {
      snapoSequence: 3,
      method: "Network.loadingFinished",
      params: {
        requestId: "large-response",
        timestamp: 1.2,
        encodedDataLength: 9_437_184,
        bodyTruncatedBytes: 4_194_304
      }
    });

    const request = state.requests.get(requestRecordKey(processId, "large-response"));
    expect(request?.encodedDataLength).toBe(9_437_184);
    expect(request?.responseBodyTruncatedBytes).toBe(4_194_304);
  });

  it("ignores duplicate and stale sequences independently for each process", () => {
    let state = createEmptyToolState();
    state = reduce(state, webSocketCreated(1));
    state = reduce(state, webSocketFrame(2, "first"));

    const afterFirstFrame = state;
    state = reduce(state, webSocketFrame(2, "duplicate"));
    expect(state).toBe(afterFirstFrame);
    expect(state.webSockets.get(webSocketRecordKey(processId, "socket-1"))?.messages).toHaveLength(1);
    expect(state.webSockets.get(webSocketRecordKey(processId, "socket-1"))?.messages[0]?.timestamp).toBe(1_500);

    state = reduce(state, webSocketFrame(1, "stale"));
    expect(state).toBe(afterFirstFrame);

    const otherProcess = "process-2";
    state = reduceCdpMessage(state, otherProcess, webSocketFrame(2, "other processId"), 1_000);
    expect(state.webSockets.get(webSocketRecordKey(otherProcess, "socket-1"))?.messages).toHaveLength(1);
  });

  it("allows sequence reset without record collisions for a new app process", () => {
    const firstInstance = "1710000000000:100000000000";
    const restartedInstance = "1710000001000:101000000000";
    const firstMessage = requestStarted("shared-request", 1);

    let state = reduceCdpMessage(createEmptyToolState(), firstInstance, firstMessage, 5_000);
    const afterFirstInstance = state;
    state = reduceCdpMessage(state, firstInstance, requestStarted("duplicate-replay", 1), 6_000);
    expect(state).toBe(afterFirstInstance);

    state = reduceCdpMessage(state, restartedInstance, firstMessage, 7_000);
    expect(state.requests.size).toBe(2);
    expect(state.requests.has(requestRecordKey(firstInstance, "shared-request"))).toBe(true);
    expect(state.requests.has(requestRecordKey(restartedInstance, "shared-request"))).toBe(true);
  });

  it("keeps child event collections and top-level records bounded", () => {
    let state = reduce(createEmptyToolState(), requestStarted("stream", 1));
    for (let index = 1; index <= toolRetentionLimits.streamEventsPerRequest + 2; index += 1) {
      state = reduce(state, {
        snapoSequence: index + 1,
        method: "Network.eventSourceMessageReceived",
        params: {
          requestId: "stream",
          timestamp: 1 + index / 1_000,
          eventId: `${index}`,
          data: `data: ${index}`
        }
      });
    }

    const stream = state.requests.get(requestRecordKey(processId, "stream"));
    expect(stream?.streamEvents).toHaveLength(toolRetentionLimits.streamEventsPerRequest);
    expect(stream?.streamEventCount).toBe(toolRetentionLimits.streamEventsPerRequest + 2);
    expect(stream?.streamEvents[0]?.sequence).toBe(3);

    state = reduce(state, requestStarted("newer", 2_000));
    const retained = enforceToolRetention(state, 1);
    expect(retained.requests.size + retained.webSockets.size).toBe(1);
    expect(retained.requests.has(requestRecordKey(processId, "newer"))).toBe(true);
  });
});

function reduce(state: ToolDataState, message: CdpMessage, receivedAt = 5_000): ToolDataState {
  return reduceCdpMessage(state, processId, message, receivedAt);
}

function readReplayFixture(): CdpMessage[] {
  return replayFixture
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line) as CdpMessage);
}

function requestStarted(requestId: string, sequence: number): CdpMessage {
  return {
    snapoSequence: sequence,
    method: "Network.requestWillBeSent",
    params: {
      requestId,
      wallTime: sequence,
      timestamp: sequence,
      request: { method: "GET", url: `https://example.com/${requestId}`, headers: {} }
    }
  };
}

function webSocketCreated(sequence: number): CdpMessage {
  return {
    snapoSequence: sequence,
    method: "Network.webSocketCreated",
    params: {
      requestId: "socket-1",
      url: "wss://example.com/socket",
      wallTime: 1,
      timestamp: 10
    }
  };
}

function webSocketFrame(sequence: number, payloadData: string): CdpMessage {
  return {
    snapoSequence: sequence,
    method: "Network.webSocketFrameReceived",
    params: {
      requestId: "socket-1",
      timestamp: 10.5,
      response: { opcode: 1, payloadData }
    }
  };
}
