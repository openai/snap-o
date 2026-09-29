// @vitest-environment jsdom
import { render } from "preact";
import { useRef } from "preact/hooks";
import { act } from "preact/test-utils";
import { afterEach, expect, it, vi } from "vitest";
import { useSearchHighlights } from "./useSearchHighlights";

const container = document.createElement("div");

class TestHighlight {
  constructor(public readonly ranges: Range[]) {}
}

function SearchFixture({ query }: { query: string }) {
  const rootRef = useRef<HTMLDivElement>(null);
  useSearchHighlights(rootRef, query);
  return (
    <div ref={rootRef}>
      <button className="record-row">GET /tbo</button>
      <div className="headers-grid">x-request: tbo</div>
      <span className="event-name">tbo</span>
      <div className="payload-scroll">
        <pre>{"tbo ".repeat(65_536)}</pre>
        <div className="json-outline">
          <div className="json-outline">tbo</div>
        </div>
      </div>
    </div>
  );
}

afterEach(() => {
  act(() => render(null, container));
  container.remove();
  vi.unstubAllGlobals();
});

it("highlights metadata without adding ranges in raw or nested JSON payloads", () => {
  const highlights = new Map<string, TestHighlight>();
  vi.stubGlobal("CSS", { highlights });
  vi.stubGlobal(
    "Highlight",
    class extends TestHighlight {
      constructor(...ranges: Range[]) {
        super(ranges);
      }
    }
  );
  document.body.append(container);

  act(() => render(<SearchFixture query="tbo" />, container));

  const ranges = highlights.get("network-search-match")!.ranges;
  expect(ranges).toHaveLength(3);
  expect(ranges.map((range) => range.toString())).toEqual(["tbo", "tbo", "tbo"]);
  expect(ranges.every((range) => range.startContainer.parentElement?.closest(".payload-scroll") == null)).toBe(true);

  act(() => render(<SearchFixture query="GET" />, container));
  expect(highlights.get("network-search-match")!.ranges.map((range) => range.toString())).toEqual(["GET"]);

  act(() => render(<SearchFixture query="" />, container));
  expect(highlights.has("network-search-match")).toBe(false);
});
