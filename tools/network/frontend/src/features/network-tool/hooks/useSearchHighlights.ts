import type { RefObject } from "preact";
import { useLayoutEffect } from "preact/hooks";
import { parseKeywordSearchQuery, searchHighlightRanges } from "../../../network/keyword-search";

const SearchHighlightName = "network-search-match";
const SearchHighlightStyleId = "network-search-match-style";
// WebKit can stall while placing highlights in large bodies. Use these highlights only for metadata.
const HighlightScopes = [
  ".record-row",
  ".detail-method",
  ".detail-header h1",
  ".status-label",
  ".failure-message",
  ".headers-grid",
  ".event-name",
  ".stream-event-metadata",
  ".stream-close-message",
  ".close-details",
  ".message-payload-size",
  ".message-enqueue-state",
  ".message-opcode"
].join(", ");

interface CustomHighlightRegistry {
  delete(name: string): void;
  set(name: string, highlight: unknown): void;
}

interface CustomHighlightApi {
  Highlight: new (...ranges: Range[]) => unknown;
  highlights: CustomHighlightRegistry;
}

export function useSearchHighlights(rootRef: RefObject<HTMLElement>, searchText: string): void {
  useLayoutEffect(() => {
    const api = customHighlightApi();
    if (api == null) return;
    ensureSearchHighlightStyle();

    api.highlights.delete(SearchHighlightName);

    const root = rootRef.current;
    if (root == null) return;

    const query = parseKeywordSearchQuery(searchText);
    let pendingFrame: number | null = null;

    const refreshHighlights = () => {
      pendingFrame = null;
      api.highlights.delete(SearchHighlightName);
      if (query.includes.length === 0) return;

      const ranges = searchRanges(root, query);
      if (ranges.length > 0) {
        api.highlights.set(SearchHighlightName, new api.Highlight(...ranges));
      }
    };

    const scheduleRefresh = () => {
      if (pendingFrame != null) return;
      pendingFrame = window.requestAnimationFrame(refreshHighlights);
    };

    refreshHighlights();

    const observer = new MutationObserver(scheduleRefresh);
    observer.observe(root, {
      childList: true,
      characterData: true,
      subtree: true
    });

    return () => {
      observer.disconnect();
      if (pendingFrame != null) window.cancelAnimationFrame(pendingFrame);
      api.highlights.delete(SearchHighlightName);
    };
  }, [rootRef, searchText]);
}

function searchRanges(root: HTMLElement, query: ReturnType<typeof parseKeywordSearchQuery>): Range[] {
  const ranges: Range[] = [];
  const visited = new Set<Node>();
  for (const scope of root.querySelectorAll(HighlightScopes)) {
    const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const text = node.textContent;
        return text == null || text.trim().length === 0 ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      }
    });

    let node = walker.nextNode();
    while (node != null) {
      if (visited.has(node) || (node.textContent?.length ?? 0) > 4096) {
        node = walker.nextNode();
        continue;
      }
      visited.add(node);
      const text = node.textContent ?? "";
      for (const match of searchHighlightRanges(text, query)) {
        const range = document.createRange();
        range.setStart(node, match.start);
        range.setEnd(node, match.end);
        ranges.push(range);
        if (ranges.length === 300) return ranges;
      }
      node = walker.nextNode();
    }
  }
  return ranges;
}

function customHighlightApi(): CustomHighlightApi | null {
  const globalWithHighlight = globalThis as typeof globalThis & {
    Highlight?: new (...ranges: Range[]) => unknown;
  };
  const cssWithHighlights = globalThis.CSS as
    | (typeof CSS & {
        highlights?: CustomHighlightRegistry;
      })
    | undefined;
  if (globalWithHighlight.Highlight == null || cssWithHighlights?.highlights == null) return null;
  return {
    Highlight: globalWithHighlight.Highlight,
    highlights: cssWithHighlights.highlights
  };
}

function ensureSearchHighlightStyle(): void {
  if (document.getElementById(SearchHighlightStyleId) != null) return;
  const style = document.createElement("style");
  style.id = SearchHighlightStyleId;
  style.textContent = `
::highlight(${SearchHighlightName}) {
  background-color: var(--search-highlight);
  color: inherit;
}`;
  document.head.append(style);
}
