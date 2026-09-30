import { expect, it } from "vitest";
import { requestBodyCoverage, responseBodyCoverage } from "./body-coverage";
import { request } from "./body-test-fixtures";
import type { RequestRecord } from "./cdp";
import { searchLocalBodies } from "./body-search";
import { matchesNetworkSearch } from "../features/network-tool/lib/search";

it.each([
  ["waiting", { status: { kind: "pending" }, endedAt: undefined }, "incomplete"],
  ["failed before headers", { status: { kind: "failure" } }, "absent"],
  ["failed after headers", { status: { kind: "failure" }, hasReceivedResponse: true }, "incomplete"],
  [
    "failed during body",
    { status: { kind: "failure" }, hasReceivedResponse: true, responseBody: "prefix" },
    "incomplete"
  ],
  ["complete", { responseBody: "full" }, "complete"],
  ["truncated", { responseBody: "prefix", responseBodyTruncatedBytes: 4 }, "incomplete"],
  ["not retained", {}, "incomplete"],
  ["HEAD", { method: "HEAD" }, "absent"]
] satisfies [string, Partial<RequestRecord>, string][])("response coverage: %s", async (_, overrides, coverage) => {
  const record = request("current", overrides);
  expect(responseBodyCoverage(record)).toBe(coverage);
  const match = await searchLocalBodies(record, ["missing"], new AbortController().signal);
  expect(matchesNetworkSearch(record, { includes: [], excludes: ["missing"] }, match)).toBe(
    coverage === "absent" || coverage === "complete"
  );
});

it.each([null, 0, 4])("request coverage uses explicit truncation: %s", (truncated) => {
  expect(requestBodyCoverage(request("current", { requestBody: "prefix", requestBodyTruncatedBytes: truncated }))).toBe(
    truncated === 0 ? "complete" : "incomplete"
  );
});
