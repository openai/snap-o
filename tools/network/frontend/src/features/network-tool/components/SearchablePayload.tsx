import { createContext, type ComponentChildren } from "preact";
import { useEffect, useMemo, useState } from "preact/hooks";
import { parseKeywordSearchQuery, type SearchHighlightRange } from "../../../network/keyword-search";
import {
  findPayloadMatches,
  payloadView,
  payloadPageSize,
  type PayloadNavigation
} from "../../../network/payload-search";

export const BodySearchContext = createContext("");

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
  const [navigation, setNavigation] = useState<PayloadNavigation>({ match: 0 });
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
        setNavigation({ match: 0 });
      })
      .catch(() => {});
    return () => abort.abort();
  }, [text, query, queryText]);
  const current = result?.text === text && result.queryText === queryText ? result : null;
  const ranges = current?.ranges ?? [];
  const { start, end, selected, previous, next, highlights } = payloadView(
    text.length,
    ranges,
    current ? navigation : { offset: 0 }
  );
  const selectMatch = (index: number) => setNavigation({ match: index });
  const blocks: ComponentChildren[] = [];
  // Short text nodes limit WebKit's work on accessibility and line positions.
  for (let position = start; position < end; position += 160) {
    const blockEnd = Math.min(end, position + 160);
    const pieces: ComponentChildren[] = [];
    let cursor = position;
    for (const range of highlights) {
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
                  : `${selected >= 0 ? `${selected + 1} of ` : ""}${ranges.length}${current.limited ? "+" : ""} matches`}
            </span>
            <button type="button" onClick={() => selectMatch(previous)} disabled={!ranges[previous]}>
              Previous match
            </button>
            <button type="button" onClick={() => selectMatch(next)} disabled={!ranges[next]}>
              Next match
            </button>
          </>
        ) : null}
      </div>
      <pre className="paged-payload">{blocks}</pre>
      {text.length > payloadPageSize ? (
        <div className="payload-search-controls">
          <button
            type="button"
            onClick={() => setNavigation({ offset: Math.max(0, start - payloadPageSize) })}
            disabled={start === 0}
          >
            Previous section
          </button>
          <span>
            Characters {start + 1}–{end} of {text.length}
          </span>
          <button type="button" onClick={() => setNavigation({ offset: end })} disabled={end === text.length}>
            Next section
          </button>
        </div>
      ) : null}
    </div>
  );
}
