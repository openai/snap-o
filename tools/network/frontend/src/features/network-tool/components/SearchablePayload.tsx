import { createContext, type ComponentChildren } from "preact";
import { useEffect, useMemo, useState } from "preact/hooks";
import { parseKeywordSearchQuery, type SearchHighlightRange } from "../../../network/keyword-search";
import { findPayloadMatches } from "../../../network/payload-search";

export const BodySearchContext = createContext("");
const pageSize = 4096;

export function SearchablePayload({
  text,
  queryText,
  controls
}: {
  text: string;
  queryText: string;
  controls: ComponentChildren;
}) {
  const query = useMemo(() => parseKeywordSearchQuery(queryText), [queryText]);
  const [offset, setOffset] = useState(0);
  const [selected, setSelected] = useState(0);
  const [result, setResult] = useState<{
    text: string;
    queryText: string;
    ranges: SearchHighlightRange[];
    limited: boolean;
  } | null>(null);
  useEffect(() => {
    const abort = new AbortController();
    void findPayloadMatches(text, query, abort.signal)
      .then((matches) => {
        if (abort.signal.aborted) return;
        setResult({ text, queryText, ...matches });
        setOffset(Math.floor((matches.ranges[0]?.start ?? 0) / pageSize) * pageSize);
        setSelected(0);
      })
      .catch(() => {});
    return () => abort.abort();
  }, [text, query, queryText]);
  const current = result?.text === text && result.queryText === queryText ? result : null;
  const ranges = current?.ranges ?? [];
  const start = Math.min(offset, Math.max(0, text.length - 1));
  const end = Math.min(text.length, start + pageSize);
  const visible = ranges.filter((range) => range.start < end && range.end > start).slice(0, 100);
  const selectMatch = (index: number) => {
    const match = ranges[index];
    if (!match) return;
    setSelected(index);
    setOffset(Math.floor(match.start / pageSize) * pageSize);
  };
  const blocks: ComponentChildren[] = [];
  // Short text nodes limit WebKit's work on accessibility and line positions.
  for (let position = start; position < end; position += 160) {
    const blockEnd = Math.min(end, position + 160);
    const pieces: ComponentChildren[] = [];
    let cursor = position;
    for (const range of visible) {
      if (range.end <= position || range.start >= blockEnd) continue;
      const from = Math.max(position, range.start);
      const to = Math.min(blockEnd, range.end);
      pieces.push(text.slice(cursor, from));
      pieces.push(<mark key={from}>{text.slice(from, to)}</mark>);
      cursor = to;
    }
    pieces.push(text.slice(cursor, blockEnd));
    blocks.push(
      <span className="payload-text-block" key={position}>
        {pieces}
      </span>
    );
  }
  return (
    <div className="searchable-payload">
      <div className="payload-search-controls">
        {controls}
        {query.includes.length > 0 ? (
          <>
            <span role="status">
              {!current
                ? "Finding matches…"
                : ranges.length === 0
                  ? "No body matches"
                  : `${selected + 1} of ${ranges.length}${current.limited ? "+" : ""} matches`}
            </span>
            <button type="button" onClick={() => selectMatch(selected - 1)} disabled={selected === 0 || !ranges.length}>
              Previous match
            </button>
            <button type="button" onClick={() => selectMatch(selected + 1)} disabled={selected + 1 >= ranges.length}>
              Next match
            </button>
          </>
        ) : null}
      </div>
      <pre className="paged-payload">{blocks}</pre>
      {text.length > pageSize ? (
        <div className="payload-search-controls">
          <button type="button" onClick={() => setOffset(Math.max(0, start - pageSize))} disabled={start === 0}>
            Previous section
          </button>
          <span>
            Characters {start + 1}–{end} of {text.length}
          </span>
          <button type="button" onClick={() => setOffset(end)} disabled={end === text.length}>
            Next section
          </button>
        </div>
      ) : null}
    </div>
  );
}
