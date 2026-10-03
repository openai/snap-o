import { useEffect, useMemo, useState } from "preact/hooks";
import type { ToolConnection } from "@snap-o/tool-host";
import type { NetworkClient } from "../../../network/client";
import type { ToolRecord } from "../../../network/cdp";
import { createBodySearch, emptyBodySearchMatches, type BodySearchMatches } from "../../../network/body-search";
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
  const [state, setState] = useState<{
    search: ReturnType<typeof createBodySearch>;
    matches: BodySearchMatches;
  } | null>(null);
  const search = useMemo(() => {
    const search = createBodySearch({
      terms,
      client,
      connection,
      onResults: (matches) => setState({ search, matches })
    });
    return search;
  }, [terms, client, connection]);
  const invalid = !validBodySearchTerms(terms);

  useEffect(() => () => search.dispose(), [search]);
  useEffect(() => {
    if (terms.length && !invalid) search.update(records);
  }, [search, records, terms, invalid]);

  if (terms.length === 0) return { matches: undefined, status: null, detail: null };
  if (invalid)
    return {
      matches: emptyBodySearchMatches,
      status: "Search is too long",
      detail: "Use at most 64 search terms, each at most 256 characters long."
    };
  const matches = state?.search === search ? state.matches : emptyBodySearchMatches;
  return { matches, status: null, detail: null };
}
