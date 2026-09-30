// @vitest-environment jsdom
import { render } from "preact";
import { useRef } from "preact/hooks";
import { useSearchHighlights } from "../hooks/useSearchHighlights";
import { act } from "preact/test-utils";
import { afterEach, expect, it, vi } from "vitest";
import { SearchablePayload } from "./SearchablePayload";

const container = document.createElement("div");
afterEach(() => {
  act(() => render(null, container));
  vi.unstubAllGlobals();
});

it("highlights metadata and the matching body section without highlighting the full payload", async () => {
  const text = "x".repeat(20_000) + "tbo" + "x".repeat(300_000);
  const highlights = new Map<string, Range[]>();
  vi.stubGlobal("CSS", { highlights });
  vi.stubGlobal("Highlight", function (...ranges: Range[]) {
    return ranges;
  });
  function Fixture() {
    const ref = useRef<HTMLDivElement>(null);
    useSearchHighlights(ref, "tbo");
    return (
      <div ref={ref}>
        <span className="record-row">GET /tbo</span>
        <div className="payload-scroll">
          <SearchablePayload text={text} queryText="tbo" controls={null} />
          <div className="json-outline">
            <div className="json-outline">tbo</div>
          </div>
        </div>
      </div>
    );
  }
  act(() => render(<Fixture />, container));
  await vi.waitFor(() => expect(container.querySelector("mark")?.textContent).toBe("tbo"));
  expect(container.querySelector("pre")!.textContent!.length).toBeLessThanOrEqual(4096);
  expect(container.querySelectorAll(".payload-text-block").length).toBeLessThanOrEqual(26);
  expect(highlights.get("network-search-match")!.map((range) => range.toString())).toEqual(["tbo"]);
  expect(highlights.get("network-search-match")![0].startContainer.parentElement?.className).toBe("record-row");
});

it("keeps the selected match highlighted within the render limit", async () => {
  const text = "hit ".repeat(100) + "hit-selected " + "hit ".repeat(150_000);
  act(() => render(<SearchablePayload text={text} queryText="hit" controls={null} />, container));
  await vi.waitFor(() => expect(container.textContent).toContain("1000+ matches"));
  const next = [...container.querySelectorAll("button")].find((button) => button.textContent === "Next match")!;
  for (let i = 0; i < 100; i++) await act(() => next.click());
  expect(container.textContent).toContain("101 of 1000+ matches");
  const highlights = [...container.querySelectorAll("mark")];
  expect(highlights.length).toBeLessThanOrEqual(100);
  expect(highlights.some((mark) => mark.nextSibling?.textContent?.startsWith("-selected"))).toBe(true);
});
