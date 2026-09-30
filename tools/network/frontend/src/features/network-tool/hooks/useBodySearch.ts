import { useEffect, useMemo, useState } from "preact/hooks";
import type { ToolConnection } from "@snap-o/tool-host";
import type { NetworkClient } from "../../../network/client";
import type { ToolRecord } from "../../../network/cdp";
import {
  emptyBodySearchMatches,
  searchCaptureBodies,
  type BodySearchCache,
  type BodySearchMatches
} from "../../../network/body-search";
import { validBodySearchTerms } from "../../../network/remote-body-search";
import { parseNetworkSearchQuery } from "../lib/search";

export function useBodySearch(
  records: ToolRecord[],
  searchText: string,
  client: NetworkClient,
  connection: ToolConnection | null
) {
  const terms = useMemo(() => {
    const query = parseNetworkSearchQuery(searchText);
    return [...new Set([...query.includes, ...query.excludes])];
  }, [searchText]);
  const key = JSON.stringify(terms);
  // Reset cached results only when the query or data source changes.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const cache = useMemo<BodySearchCache>(() => new Map(), [key, client, connection]);
  const [state, setState] = useState<{
    key: string;
    connection: ToolConnection | null;
    matches: BodySearchMatches;
  }>({
    key: "",
    connection,
    matches: emptyBodySearchMatches
  });
  const invalid = !validBodySearchTerms(terms);

  useEffect(() => {
    if (key === "[]" || invalid) return;
    const abort = new AbortController();
    const tokens = JSON.parse(key) as string[];
    void searchCaptureBodies(
      records,
      tokens,
      client,
      connection,
      abort.signal,
      (matches) => {
        if (!abort.signal.aborted) setState({ key, connection, matches });
      },
      cache
    ).catch(() => {});
    return () => abort.abort();
  }, [records, key, invalid, client, connection, cache]);

  if (terms.length === 0) return { matches: undefined, status: null, detail: null };
  if (invalid)
    return {
      matches: emptyBodySearchMatches,
      status: "Search is too long",
      detail: "Use at most 64 search terms, each at most 256 characters long."
    };
  const current = state.key === key && state.connection === connection;
  const matches = current ? state.matches : emptyBodySearchMatches;
  return { matches, status: null, detail: null };
}
