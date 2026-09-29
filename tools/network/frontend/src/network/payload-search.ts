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
