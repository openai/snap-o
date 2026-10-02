// @vitest-environment jsdom
import { render } from "preact";
import { useRef } from "preact/hooks";
import { useSearchHighlights } from "../hooks/useSearchHighlights";
import { act } from "preact/test-utils";
import { afterEach, expect, it, vi } from "vitest";
import { findPayloadMatches, payloadView } from "../../../network/payload-search";
import { parseKeywordSearchQuery } from "../../../network/keyword-search";
import { SearchablePayload } from "./SearchablePayload";

const container = document.createElement("div");
afterEach(() => {
  act(() => render(null, container));
  vi.unstubAllGlobals();
});

it("highlights metadata and the matching body section without highlighting the full payload", async () => {
  const text = "x".repeat(20_479) + "tbo" + "x".repeat(4093) + "tbo" + "x".repeat(300_000);
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
  const click = (label: string) =>
    act(() => [...container.querySelectorAll("button")].find((b) => b.textContent === label)!.click());
  click("Next match");
  expect(container.querySelector('[role="status"]')?.textContent).toBe("2 of 2 matches");
  expect(container.querySelector("mark")?.textContent).toBe("tbo");
  click("Next section");
  expect(container.querySelector('[role="status"]')?.textContent).toBe("2 matches");
  click("Previous match");
  expect(container.querySelector('[role="status"]')?.textContent).toBe("2 of 2 matches");
  expect(container.querySelector("mark")?.textContent).toBe("tbo");
});

it.each([4095, 4096, 8191])("shows the whole selected match at %i within display limits", async (start) => {
  const text = "x".repeat(start - 700) + "needle ".repeat(1001);
  const { ranges, limited } = await findPayloadMatches(
    text,
    parseKeywordSearchQuery("needle"),
    new AbortController().signal
  );
  expect(ranges).toHaveLength(1000);
  expect(limited).toBe(true);
  const view = payloadView(text.length, ranges, { match: 100 });
  expect(view.highlights[0]).toEqual(ranges[100]);
  expect(view.start).toBeLessThanOrEqual(ranges[100].start);
  expect(view.end).toBeGreaterThanOrEqual(ranges[100].end);
  expect(view.highlights.length).toBeLessThanOrEqual(100);
  expect(view.end - view.start).toBeLessThanOrEqual(4096);
});
