// @vitest-environment jsdom
import { render } from "preact";
import { act } from "preact/test-utils";
import { expect, it, vi } from "vitest";
import type { ToolConnection } from "@snap-o/tool-host";
import type { NetworkClient } from "../../../network/client";
import type { RequestRecord } from "../../../network/cdp";
import { request } from "../../../network/body-test-fixtures";
import { filterRecords } from "../lib/records";
import { useBodySearch } from "./useBodySearch";

it("keeps matches while new records are searched and Android is stalled", async () => {
  const container = document.createElement("div");
  const connection = { processIdentity: "current" } as ToolConnection;
  const searchBodies = vi.fn<NonNullable<NetworkClient["searchBodies"]>>(async () => {
    return {
      results: [
        { requestId: "remote", request: { terms: [], complete: true }, response: { terms: ["needle"], complete: true } }
      ]
    };
  });
  const client = { searchBodies } as unknown as NetworkClient;
  const frames: string[][] = [];
  function Fixture({ records, query = "needle" }: { records: RequestRecord[]; query?: string }) {
    const { matches } = useBodySearch(records, query, client, connection);
    const ids = filterRecords(records, query, false, [], matches).flatMap((r) =>
      r.kind === "request" ? [r.requestId] : []
    );
    frames.push(ids);
    return <div>{ids.join(",")}</div>;
  }
  const records = [
    request("current", { requestId: "local", responseBody: "needle" }),
    request("current", { requestId: "remote" }),
    request("current", { requestId: "changed", responseBody: "waiting" })
  ];
  try {
    act(() => render(<Fixture records={records} />, container));
    await vi.waitFor(() => expect(container.textContent).toContain("remote"));
    const previousIds = frames.at(-1)!;
    searchBodies.mockImplementation(() => new Promise(() => {}));
    const waiting = [...records, request("current", { requestId: "waiting" })];
    act(() => render(<Fixture records={waiting} />, container));
    await vi.waitFor(() => expect(searchBodies).toHaveBeenCalledTimes(2));
    const firstFrame = frames.length;
    const firstSignal = searchBodies.mock.calls[1][1];
    const next = [
      request("current", { requestId: "new", responseBody: "needle" }),
      ...waiting.map((r) => (r.requestId === "changed" ? { ...r, responseBody: "now needle", updatedAt: 3 } : r))
    ];
    act(() => render(<Fixture records={next} />, container));
    await vi.waitFor(() => expect(container.textContent).toContain("changed"));
    expect(container.textContent).toContain("new");
    expect(firstSignal.aborted).toBe(false);
    expect(searchBodies).toHaveBeenCalledTimes(2);
    for (const frame of frames.slice(firstFrame)) expect(frame).toEqual(expect.arrayContaining(previousIds));
    expect(searchBodies.mock.calls[1][0].requestIds).not.toContain("remote");
    act(() => render(<Fixture records={next} query="absent" />, container));
    expect(firstSignal.aborted).toBe(true);
    expect(container.textContent).toBe("");
  } finally {
    act(() => render(null, container));
  }
});
