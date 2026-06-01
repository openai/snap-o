import { useMemo } from "react";
import { parseKeywordSearchQuery, searchHighlightRanges } from "../../../network/keyword-search";

export function HighlightText({ text, searchText }: { text: string; searchText: string }): React.ReactNode {
  const query = useMemo(() => parseKeywordSearchQuery(searchText), [searchText]);
  const ranges = useMemo(() => searchHighlightRanges(text, query), [query, text]);
  if (ranges.length === 0) return text;

  const parts: React.ReactNode[] = [];
  let index = 0;
  ranges.forEach((range, rangeIndex) => {
    if (range.start > index) parts.push(text.slice(index, range.start));
    parts.push(
      <mark className="search-highlight" key={`${range.start}:${range.end}:${rangeIndex}`}>
        {text.slice(range.start, range.end)}
      </mark>
    );
    index = range.end;
  });
  if (index < text.length) parts.push(text.slice(index));
  return parts;
}
