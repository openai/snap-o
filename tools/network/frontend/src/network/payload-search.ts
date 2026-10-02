import { searchHighlightRanges, type KeywordSearchQuery, type SearchHighlightRange } from "./keyword-search";
import { yieldSearch } from "./remote-body-search";

export async function findPayloadMatches(
  text: string,
  query: KeywordSearchQuery,
  signal: AbortSignal
): Promise<{ ranges: SearchHighlightRange[]; limited: boolean }> {
  const ranges: SearchHighlightRange[] = [];
  if (query.includes.length === 0 || query.includes.length > 64 || query.includes.some((term) => term.length > 256))
    return { ranges, limited: false };
  const overlap = Math.max(...query.includes.map((term) => term.length));
  await yieldSearch(signal);
  let deadline = performance.now() + 4;
  for (let start = 0; start < text.length; start += 4096) {
    signal.throwIfAborted();
    if (performance.now() >= deadline) {
      await yieldSearch(signal);
      deadline = performance.now() + 4;
    }
    for (const match of searchHighlightRanges(text.slice(start, start + 4096 + overlap), query)) {
      if (match.start >= 4096) continue;
      const range = { start: start + match.start, end: start + match.end };
      if (range.start < (ranges.at(-1)?.end ?? 0)) continue;
      ranges.push(range);
      if (ranges.length === 1000) return { ranges, limited: true };
    }
  }
  return { ranges, limited: false };
}

export type PayloadNavigation = { match: number } | { offset: number };
export const payloadPageSize = 4096;

export function payloadView(length: number, ranges: SearchHighlightRange[], navigation: PayloadNavigation) {
  const selected = "match" in navigation && ranges[navigation.match] ? navigation.match : -1;
  const offset = "offset" in navigation ? navigation.offset : (ranges[selected]?.start ?? 0);
  const start = Math.max(0, Math.min(offset, length));
  const end = Math.min(length, start + payloadPageSize);
  const after = ranges.findIndex((range) => range.start >= start);
  return {
    start,
    end,
    selected,
    previous: selected >= 0 ? selected - 1 : (after < 0 ? ranges.length : after) - 1,
    next: selected >= 0 ? selected + 1 : after,
    highlights: ranges.filter((range) => range.start < end && range.end > start).slice(0, 100)
  };
}
