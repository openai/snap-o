/// <reference types="vite/client" />

import { describe, expect, it } from "vitest";
import replayFixture from "../../../contracts/network/v1/http-replay.jsonl?raw";
import {
  createEmptyInspectorState,
  enforceInspectorRetention,
  inspectorRetentionLimits,
  reduceCdpMessage,
  requestRecordKey,
  serverMatches,
  webSocketRecordKey,
  type InspectorDataState,
  type ServerId
} from "./cdp";
import type { CdpMessage } from "./bridge-types";

const server: ServerId = { deviceId: "device-a", socketName: "snapo_network_1" };

describe("reduceCdpMessage", () => {
  it("uses monotonic protocol time from the shared replay contract", () => {
    let state = createEmptyInspectorState();
    for (const message of readReplayFixture()) {
      state = reduce(state, message, 9_000_000_000_000);
    }

    const request = state.requests.get(requestRecordKey(server, "request-1"));
    expect(request?.startedAt).toBe(1_710_000_000_000);
    expect(request?.endedAt).toBe(1_710_000_000_250);
    expect(request?.updatedAt).toBe(1_710_000_000_250);
  });

  it("ignores duplicate and stale sequences independently for each server", () => {
    let state = createEmptyInspectorState();
    state = reduce(state, webSocketCreated(1));
    state = reduce(state, webSocketFrame(2, "first"));

    const afterFirstFrame = state;
    state = reduce(state, webSocketFrame(2, "duplicate"));
    expect(state).toBe(afterFirstFrame);
    expect(state.webSockets.get(webSocketRecordKey(server, "socket-1"))?.messages).toHaveLength(1);
    expect(state.webSockets.get(webSocketRecordKey(server, "socket-1"))?.messages[0]?.timestamp).toBe(1_500);

    state = reduce(state, webSocketFrame(1, "stale"));
    expect(state).toBe(afterFirstFrame);

    const otherServer = { deviceId: "device-b", socketName: "snapo_network_2" };
    state = reduceCdpMessage(state, otherServer, webSocketFrame(2, "other server"), 1_000);
    expect(state.webSockets.get(webSocketRecordKey(otherServer, "socket-1"))?.messages).toHaveLength(1);
  });

  it("allows sequence reset without record collisions for a new server instance", () => {
    const firstInstance = { ...server, instanceId: "1710000000000:100000000000" };
    const restartedInstance = { ...server, instanceId: "1710000001000:101000000000" };
    const firstMessage = requestStarted("shared-request", 1);

    let state = reduceCdpMessage(createEmptyInspectorState(), firstInstance, firstMessage, 5_000);
    const afterFirstInstance = state;
    state = reduceCdpMessage(state, firstInstance, requestStarted("duplicate-replay", 1), 6_000);
    expect(state).toBe(afterFirstInstance);

    state = reduceCdpMessage(state, restartedInstance, firstMessage, 7_000);
    expect(state.requests.size).toBe(2);
    expect(state.requests.has(requestRecordKey(firstInstance, "shared-request"))).toBe(true);
    expect(state.requests.has(requestRecordKey(restartedInstance, "shared-request"))).toBe(true);
    expect(serverMatches(firstInstance, restartedInstance)).toBe(true);
  });

  it("keeps child event collections and top-level records bounded", () => {
    let state = reduce(createEmptyInspectorState(), requestStarted("stream", 1));
    for (let index = 1; index <= inspectorRetentionLimits.streamEventsPerRequest + 2; index += 1) {
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

    const stream = state.requests.get(requestRecordKey(server, "stream"));
    expect(stream?.streamEvents).toHaveLength(inspectorRetentionLimits.streamEventsPerRequest);
    expect(stream?.streamEventCount).toBe(inspectorRetentionLimits.streamEventsPerRequest + 2);
    expect(stream?.streamEvents[0]?.sequence).toBe(3);

    state = reduce(state, requestStarted("newer", 2_000));
    const retained = enforceInspectorRetention(state, 1);
    expect(retained.requests.size + retained.webSockets.size).toBe(1);
    expect(retained.requests.has(requestRecordKey(server, "newer"))).toBe(true);
  });
});

function reduce(state: InspectorDataState, message: CdpMessage, receivedAt = 5_000): InspectorDataState {
  return reduceCdpMessage(state, server, message, receivedAt);
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
