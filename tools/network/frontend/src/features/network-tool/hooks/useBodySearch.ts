import { useCallback, useEffect, useMemo, useState } from "preact/hooks";
import type { ToolConnection } from "@snap-o/tool-host";
import type { NetworkClient } from "../../../network/client";
import type { ToolRecord } from "../../../network/cdp";
import {
  emptyBodySearchMatches,
  searchLocalCapture,
  searchAndroidCapture,
  bodySearchMatches,
  type BodySearchCache
} from "../../../network/body-search";
import { validBodySearchTerms } from "../../../network/remote-body-search";
import { parseNetworkSearchQuery } from "../lib/search";

export function useBodySearch(
  records: ToolRecord[],
  searchText: string,
  client: NetworkClient,
  connection: ToolConnection | null
) {
  const query = parseNetworkSearchQuery(searchText);
  const key = JSON.stringify([...new Set([...query.includes, ...query.excludes])]);
  const terms = useMemo<string[]>(() => JSON.parse(key), [key]);
  // Start a new cache when the query or data source changes.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const cache = useMemo<BodySearchCache>(() => new Map(), [terms, client, connection]);
  const [state, setState] = useState({ cache, matches: emptyBodySearchMatches });
  const invalid = !validBodySearchTerms(terms);

  const publish = useCallback(() => setState({ cache, matches: bodySearchMatches(cache) }), [cache]);
  useEffect(() => {
    if (terms.length === 0 || invalid) return;
    const abort = new AbortController();
    void searchLocalCapture(records, terms, abort.signal, cache, publish).catch(() => {});
    return () => abort.abort();
  }, [records, terms, invalid, cache, publish]);

  useEffect(() => {
    if (terms.length === 0 || invalid || !connection) return;
    const abort = new AbortController();
    void searchAndroidCapture(terms, client, connection, abort.signal, cache, publish).catch(() => {});
    return () => abort.abort();
  }, [terms, invalid, client, connection, cache, publish]);

  if (terms.length === 0) return { matches: undefined, status: null, detail: null };
  if (invalid)
    return {
      matches: emptyBodySearchMatches,
      status: "Search is too long",
      detail: "Use at most 64 search terms, each at most 256 characters long."
    };
  const matches = state.cache === cache ? state.matches : emptyBodySearchMatches;
  return { matches, status: null, detail: null };
}
