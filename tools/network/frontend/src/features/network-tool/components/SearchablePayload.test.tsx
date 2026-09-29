// @vitest-environment jsdom
import { render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, expect, it, vi } from "vitest";
import { SearchablePayload } from "./SearchablePayload";

const container = document.createElement("div");
afterEach(() => act(() => render(null, container)));

it("opens the section containing a match without rendering the full body", async () => {
  const text = "x".repeat(20_000) + "tbo" + "x".repeat(300_000);
  act(() => render(<SearchablePayload text={text} queryText="tbo" controls={null} />, container));
  await vi.waitFor(() => expect(container.querySelector("mark")?.textContent).toBe("tbo"));
  expect(container.querySelector("pre")!.textContent!.length).toBeLessThanOrEqual(4096);
  expect(container.querySelectorAll(".payload-text-block").length).toBeLessThanOrEqual(26);
});

it("bounds inline highlights even for a common one-letter query", async () => {
  act(() => render(<SearchablePayload text={"t ".repeat(150_000)} queryText="t" controls={null} />, container));
  await vi.waitFor(() => expect(container.textContent).toContain("1000+ matches"));
  expect(container.querySelectorAll("mark").length).toBeLessThanOrEqual(100);
});
