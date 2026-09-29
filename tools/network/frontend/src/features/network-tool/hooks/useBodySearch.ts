import { useEffect, useMemo, useRef, useState } from "preact/hooks";
import type { ToolConnection } from "@snap-o/tool-host";
import type { NetworkClient } from "../../../network/client";
import type { ToolRecord } from "../../../network/cdp";
import {
  emptyBodySearchMatches,
  searchCaptureBodies,
  yieldSearch,
  type BodySearchCache,
  type BodySearchMatches
} from "../../../network/body-search";
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
  const latestRef = useRef(records);
  useEffect(() => {
    latestRef.current = records;
  }, [records]);
  const [state, setState] = useState<{
    key: string;
    connection: ToolConnection | null;
    matches: BodySearchMatches;
  }>({
    key: "",
    connection,
    matches: emptyBodySearchMatches
  });
  const invalid = terms.length > 64 || terms.some((term) => term.length > 256);

  useEffect(() => {
    if (key === "[]" || invalid) return;
    const abort = new AbortController();
    const tokens = JSON.parse(key) as string[];
    const run = async () => {
      const cache: BodySearchCache = new Map();
      let previous: ToolRecord[] | null = null;
      while (!abort.signal.aborted) {
        const snapshot = latestRef.current;
        if (snapshot !== previous) {
          previous = snapshot;
          await searchCaptureBodies(
            snapshot,
            tokens,
            client,
            connection,
            abort.signal,
            (matches) => {
              if (!abort.signal.aborted) setState({ key, connection, matches });
            },
            cache
          );
        }
        await yieldSearch(abort.signal, 500);
      }
    };
    void run().catch(() => {});
    return () => abort.abort();
  }, [key, invalid, client, connection]);

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
