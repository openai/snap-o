// @vitest-environment jsdom

import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { NetworkClient } from "../../../network/client";
import { recordId, type RequestRecord } from "../../../network/cdp";
import { RecordList } from "./RecordList";

const records = [request("first"), request("second"), request("third")];
const copyText = vi.fn().mockResolvedValue(undefined);
const client = { copyText } as unknown as NetworkClient;
const onSelect = vi.fn();
const scrollIntoView = vi.fn();
let container: HTMLDivElement;
let root: Root;

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  Object.defineProperty(Element.prototype, "scrollIntoView", { configurable: true, value: scrollIntoView });
  onSelect.mockClear();
  copyText.mockClear();
  scrollIntoView.mockClear();
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
});

afterEach(() => {
  act(() => root.unmount());
  container.remove();
  Reflect.deleteProperty(Element.prototype, "scrollIntoView");
  vi.unstubAllGlobals();
});

function render(visibleRecords = records, initialId: string | null = recordId(records[0])) {
  act(() => root.render(<Harness records={visibleRecords} initialId={initialId} />));
  return container.querySelector<HTMLDivElement>('[role="listbox"]')!;
}

function Harness({ records: visibleRecords, initialId }: { records: RequestRecord[]; initialId: string | null }) {
  const [selectedId, setSelectedId] = useState(initialId);
  return (
    <>
      <input aria-label="Filter" />
      <RecordList
        records={visibleRecords}
        allRecords={records}
        placeholder={null}
        selectedRecordId={selectedId}
        onSelect={(id) => {
          onSelect(id);
          setSelectedId(id);
        }}
        client={client}
      />
    </>
  );
}

function press(target: Element, key: string, options: KeyboardEventInit = {}) {
  const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...options });
  act(() => {
    target.dispatchEvent(event);
  });
  return event;
}

function openNativeContextMenu(target: Element, options: MouseEventInit = {}) {
  const event = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, ...options });
  act(() => {
    target.dispatchEvent(event);
  });
  return event;
}

function expectSelected(list: HTMLElement, label: string) {
  const selected = list.querySelector('[aria-selected="true"]')!;
  expect(selected.textContent).toContain(label);
  expect(list.getAttribute("aria-activedescendant")).toBe(selected.id);
  expect(list.querySelectorAll('[aria-selected="true"]')).toHaveLength(1);
}

describe("network request keyboard selection", () => {
  it("owns focus after a click and moves selection instead of scrolling", () => {
    const list = render();
    const options = list.querySelectorAll<HTMLButtonElement>('[role="option"]');

    // A synthetic click does not focus the button, like a mouse click in macOS WebKit.
    act(() => options[1].click());
    expect(document.activeElement).toBe(list);
    expectSelected(list, "second");
    expect(list.tabIndex).toBe(0);
    expect([...options].every((option) => option.tabIndex === -1)).toBe(true);

    expect(press(list, "ArrowDown").defaultPrevented).toBe(true);
    expectSelected(list, "third");
    expect(scrollIntoView).toHaveBeenLastCalledWith({ block: "nearest" });
    expect(scrollIntoView.mock.instances.at(-1)).toBe(options[2]);
    expect(document.activeElement).toBe(list);

    expect(press(list, "ArrowUp").defaultPrevented).toBe(true);
    expectSelected(list, "second");
  });

  it("uses the current filtered and sorted order", () => {
    const list = render();
    render([records[2], records[0]]);
    press(list, "ArrowUp");
    expect(onSelect).toHaveBeenLastCalledWith(recordId(records[2]));
    expectSelected(list, "third");
    press(list, "ArrowDown");
    expectSelected(list, "first");
  });

  it("clamps at each end and supports Home and End", () => {
    const list = render();
    expect(press(list, "ArrowUp").defaultPrevented).toBe(true);
    expect(onSelect).not.toHaveBeenCalled();
    expect(press(list, "End").defaultPrevented).toBe(true);
    expectSelected(list, "third");
    onSelect.mockClear();
    expect(press(list, "ArrowDown").defaultPrevented).toBe(true);
    expect(onSelect).not.toHaveBeenCalled();
    expect(press(list, "Home").defaultPrevented).toBe(true);
    expectSelected(list, "first");
  });

  it.each([
    ["ArrowDown", "first"],
    ["ArrowUp", "third"]
  ])("starts at the appropriate end for %s without a selection", (key, label) => {
    const list = render(records, null);
    press(list, key);
    expectSelected(list, label);
  });

  it("leaves unrelated controls, modified keys, and composition alone", () => {
    const list = render();
    const filter = container.querySelector("input")!;
    filter.focus();
    expect(press(filter, "ArrowDown").defaultPrevented).toBe(false);
    expect(document.activeElement).toBe(filter);
    for (const modifiers of [
      { altKey: true },
      { ctrlKey: true },
      { metaKey: true },
      { shiftKey: true },
      { isComposing: true }
    ]) {
      expect(press(list, "ArrowDown", modifiers).defaultPrevented).toBe(false);
    }
    expect(press(list, "ArrowLeft").defaultPrevented).toBe(false);
    expect(onSelect).not.toHaveBeenCalled();
    expect(scrollIntoView).not.toHaveBeenCalled();
  });

  it("does nothing for an empty list", () => {
    const list = render([], null);
    expect(press(list, "ArrowDown").defaultPrevented).toBe(false);
    expect(onSelect).not.toHaveBeenCalled();
    expect(scrollIntoView).not.toHaveBeenCalled();
  });

  it.each(["Shift+F10", "ContextMenu", "native contextmenu"])(
    "opens the active request's menu with %s and returns focus after an action",
    (gesture) => {
      const list = render();
      list.focus();
      press(list, "ArrowDown");
      const option = list.querySelector('[aria-selected="true"]')!;
      vi.spyOn(option, "getBoundingClientRect").mockReturnValue({ left: 24, bottom: 88 } as DOMRect);

      const event =
        gesture === "native contextmenu"
          ? openNativeContextMenu(list)
          : press(list, gesture === "Shift+F10" ? "F10" : "ContextMenu", { shiftKey: gesture === "Shift+F10" });

      expect(event.defaultPrevented).toBe(true);
      const menu = container.querySelector<HTMLElement>('[role="menu"]')!;
      expect(menu).not.toBeNull();
      expect(menu.style.left).toBe("24px");
      expect(menu.style.top).toBe("88px");
      const items = [...menu.querySelectorAll<HTMLButtonElement>('[role="menuitem"]')];
      expect(items.map((item) => item.textContent)).toEqual(["Copy URL", "Copy as cURL", "Export HAR (sanitized)..."]);
      expect(document.activeElement).toBe(items[0]);

      expect(press(items[0], "ArrowDown").defaultPrevented).toBe(true);
      expect(document.activeElement).toBe(items[1]);
      press(items[1], "End");
      expect(document.activeElement).toBe(items[2]);
      press(items[2], "Home");
      expect(document.activeElement).toBe(items[0]);
      expectSelected(list, "second");

      press(items[0], "Enter");
      expect(copyText).toHaveBeenCalledWith(records[1].url);
      expect(container.querySelector('[role="menu"]')).toBeNull();
      expect(document.activeElement).toBe(list);
      press(list, "ArrowDown");
      expectSelected(list, "third");
    }
  );

  it("dismisses the keyboard menu with Escape without invoking an action", () => {
    const list = render();
    list.focus();
    press(list, "F10", { shiftKey: true });
    const firstItem = container.querySelector('[role="menuitem"]')!;
    press(firstItem, "ArrowUp");
    expect(document.activeElement?.textContent).toBe("Export HAR (sanitized)...");
    expect(press(document.activeElement!, "Escape").defaultPrevented).toBe(true);
    expect(container.querySelector('[role="menu"]')).toBeNull();
    expect(document.activeElement).toBe(list);
    expect(copyText).not.toHaveBeenCalled();
  });

  it("keeps pointer context menus attached to the clicked request", () => {
    const list = render();
    const options = list.querySelectorAll('[role="option"]');
    expect(openNativeContextMenu(options[2], { clientX: 70, clientY: 110 }).defaultPrevented).toBe(true);
    expectSelected(list, "third");
    const menu = container.querySelector<HTMLElement>('[role="menu"]')!;
    expect(menu.style.left).toBe("70px");
    expect(menu.style.top).toBe("110px");
    act(() => menu.querySelector<HTMLButtonElement>('[role="menuitem"]')!.click());
    expect(copyText).toHaveBeenCalledWith(records[2].url);
  });

  it("does not open a keyboard menu without an active request", () => {
    const list = render([], null);
    expect(press(list, "F10", { shiftKey: true }).defaultPrevented).toBe(false);
    expect(press(list, "ContextMenu").defaultPrevented).toBe(false);
    expect(openNativeContextMenu(list).defaultPrevented).toBe(false);
    expect(container.querySelector('[role="menu"]')).toBeNull();
  });
});

function request(id: string): RequestRecord {
  return {
    kind: "request",
    server: { deviceId: "device", socketName: "socket", instanceId: "instance" },
    requestId: id,
    method: "GET",
    url: `https://example.com/${id}`,
    requestHeaders: [],
    responseHeaders: [],
    status: { kind: "success", code: 200 },
    startedAt: 1,
    endedAt: 2,
    streamEvents: [],
    streamEventCount: 0,
    updatedAt: 2
  };
}
