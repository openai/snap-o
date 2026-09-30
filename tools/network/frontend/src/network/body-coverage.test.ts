import { expect, it } from "vitest";
import { request } from "./body-test-fixtures";
import type { RequestRecord } from "./cdp";
import { searchLocalBodies, mergeBodyMatches } from "./body-search";
import { matchesNetworkSearch } from "../features/network-tool/lib/search";

it.each([
  ["waiting", { status: { kind: "pending" }, endedAt: undefined }, false],
  ["failed before headers", { status: { kind: "failure" } }, true],
  ["failed after headers", { status: { kind: "failure" }, hasReceivedResponse: true }, false],
  ["failed during body", { status: { kind: "failure" }, hasReceivedResponse: true, responseBody: "prefix" }, false],
  ["complete", { responseBody: "full" }, true],
  ["truncated", { responseBody: "prefix", responseBodyTruncatedBytes: 4 }, false],
  ["not retained", {}, false],
  ["HEAD", { method: "HEAD" }, true]
] satisfies [string, Partial<RequestRecord>, boolean][])(
  "exclusion search after %s",
  async (_, overrides, complete) => {
    const record = request("current", overrides);
    const match = await searchLocalBodies(record, ["missing"], new AbortController().signal);
    expect(matchesNetworkSearch(record, { includes: [], excludes: ["missing"] }, match)).toBe(complete);
  }
);

it("merges sources before checking excluded terms", async () => {
  const record = request("current", { responseBody: "wanted forbidden" });
  const local = await searchLocalBodies(record, ["wanted", "forbidden"], new AbortController().signal);
  const remote = { ...local, response: { terms: ["wanted"], complete: true } };
  expect(
    matchesNetworkSearch(record, { includes: ["wanted"], excludes: ["forbidden"] }, mergeBodyMatches(local, remote))
  ).toBe(false);
  const partial = { ...remote, response: { ...remote.response, complete: false } };
  expect(matchesNetworkSearch(record, { includes: ["wanted"], excludes: [] }, partial)).toBe(true);
  expect(matchesNetworkSearch(record, { includes: ["wanted"], excludes: ["missing"] }, partial)).toBe(false);
});
