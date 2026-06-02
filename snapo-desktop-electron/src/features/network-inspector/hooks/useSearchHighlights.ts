import { useLayoutEffect, type RefObject } from "react";
import { parseKeywordSearchQuery, searchHighlightRanges } from "../../../network/keyword-search";

const SearchHighlightName = "network-search-match";
const SearchHighlightStyleId = "network-search-match-style";
const HighlightScopes = [
  ".record-row",
  ".detail-method",
  ".detail-header h1",
  ".status-label",
  ".failure-message",
  ".headers-grid",
  ".payload-scroll pre",
  ".json-outline",
  ".event-name",
  ".stream-event-metadata",
  ".stream-closed-info",
  ".close-details",
  ".message-payload-size",
  ".message-enqueue-state",
  ".message-opcode"
].join(", ");
const HighlightIgnoreScopes = ".json-row-trailing";

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
  for (const scope of root.querySelectorAll(HighlightScopes)) {
    const walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const text = node.textContent;
        if (node.parentElement?.closest(HighlightIgnoreScopes) != null) return NodeFilter.FILTER_REJECT;
        return text == null || text.trim().length === 0 ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
      }
    });

    let node = walker.nextNode();
    while (node != null) {
      const text = node.textContent ?? "";
      for (const match of searchHighlightRanges(text, query)) {
        const range = document.createRange();
        range.setStart(node, match.start);
        range.setEnd(node, match.end);
        ranges.push(range);
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
