import { expect, it } from "vitest";
import { searchHighlightRanges, parseKeywordSearchQuery, matchesKeywordSearchDocument } from "./keyword-search";
import { findPayloadMatches } from "./payload-search";
import { searchBodyText } from "./body-search";

it.each([
  ["İabc", "abc", "abc"],
  ["😀İABC", "abc", "ABC"],
  ["İ", "i", "İ"],
  ["x[a]x", "[a]", "[a]"],
  ["ΟΣ", "ος", "ΟΣ"]
])("matching and highlighting agree for %s", async (text, term, expected) => {
  const query = parseKeywordSearchQuery(term);
  expect(matchesKeywordSearchDocument({ parts: [text] }, query)).toBe(true);
  const ranges = searchHighlightRanges(text, query);
  expect(ranges.map(({ start, end }) => text.slice(start, end))).toEqual([expected]);
  const body = await searchBodyText(text, query.includes, new AbortController().signal);
  expect(body.terms).toEqual(query.includes);
});

it("preserves offsets across chunks and in snippets", async () => {
  const text = "İ".repeat(16_383) + "abc" + "x".repeat(100);
  const query = parseKeywordSearchQuery("abc");
  const result = await findPayloadMatches(text, query, new AbortController().signal);
  expect(result.ranges).toEqual([{ start: 16_383, end: 16_386 }]);
  expect((await searchBodyText(text, query.includes, new AbortController().signal)).snippet).toContain("abc");
});

it("can cancel a large body search", async () => {
  const abort = new AbortController();
  const pending = searchBodyText("x".repeat(1_000_000), ["missing"], abort.signal);
  abort.abort();
  await expect(pending).rejects.toThrow();
});
