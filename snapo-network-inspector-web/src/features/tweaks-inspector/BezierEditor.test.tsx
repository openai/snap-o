// @vitest-environment jsdom
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BezierEditor } from "./BezierEditor";
import type { BezierValue } from "../../network/bridge-types";

const initial = { x1: 0.4, y1: 0, x2: 0.2, y2: 1 };

describe("Bezier editor", () => {
  let container: HTMLDivElement;
  let root: Root;
  const changed = vi.fn();
  const reset = vi.fn();
  beforeEach(async () => {
    vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
    container = document.createElement("div");
    document.body.append(container);
    root = createRoot(container);
    changed.mockClear();
    reset.mockClear();
    function Harness() {
      const [value, setValue] = useState(initial);
      return (
        <BezierEditor
          tweak={{ name: "Motion/Curve", type: "bezier", value, default: initial }}
          onChange={(next: BezierValue) => {
            changed(next);
            setValue(next);
          }}
          onReset={() => {
            reset();
            setValue(initial);
          }}
        />
      );
    }
    await act(async () => root.render(<Harness />));
    await act(async () => container.querySelector("button")!.click());
  });
  afterEach(async () => {
    await act(async () => root.unmount());
    container.remove();
    vi.unstubAllGlobals();
  });
  it("opens a dialog and emits one complete object for a keyboard adjustment", async () => {
    expect(document.querySelector('[role="dialog"]')).not.toBeNull();
    const handle = document.querySelector('[role="button"]')!;
    await act(async () => handle.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })));
    expect(changed).toHaveBeenLastCalledWith({ x1: 0.41, y1: 0, x2: 0.2, y2: 1 });
  });
  it("applies a whole preset and invokes the source reset", async () => {
    const preset = document.querySelector<HTMLButtonElement>('[aria-label="Ease out"]')!;
    await act(async () => preset.click());
    expect(preset.getAttribute("aria-pressed")).toBe("true");
    expect(changed).toHaveBeenLastCalledWith({ x1: 0, y1: 0, x2: 0.58, y2: 1 });
    await act(async () => document.querySelector<HTMLButtonElement>('[aria-label="Reset curve"]')!.click());
    expect(reset).toHaveBeenCalledOnce();
    expect(document.querySelector<HTMLInputElement>('[aria-label="Motion/Curve X1"]')!.value).toBe("0.4");
  });
  it("keeps an unfinished coordinate local until it becomes valid", async () => {
    const input = document.querySelector<HTMLInputElement>('[aria-label="Motion/Curve Y2"]')!;
    const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    await act(async () => {
      setValue.call(input, "");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(input.value).toBe("");
    expect(changed).not.toHaveBeenCalled();
    await act(async () => {
      setValue.call(input, "1e99");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(changed).not.toHaveBeenCalled();
    await act(async () => {
      setValue.call(input, "1.5");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(changed).toHaveBeenLastCalledWith({ ...initial, y2: 1.5 });
  });

  it("keeps the inspector and graph mounted across live changes", async () => {
    const panel = document.querySelector('[role="dialog"]')!;
    const graph = document.querySelector(".bezier-graph")!;
    const handle = document.querySelector('[role="button"]')!;
    await act(async () => handle.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true })));
    expect(document.querySelector('[role="dialog"]')).toBe(panel);
    expect(document.querySelector(".bezier-graph")).toBe(graph);
    expect(document.querySelector('[role="button"]')).toBe(handle);
  });

  it("closes on Escape and returns focus to the swatch", async () => {
    await act(async () => window.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" })));
    expect(document.querySelector('[role="dialog"]')).toBeNull();
    expect(document.activeElement).toBe(container.querySelector("button"));
  });

  it("dismisses on an outside click but keeps editing on inside clicks", async () => {
    await act(async () => document.querySelector("input")!.dispatchEvent(new Event("pointerdown", { bubbles: true })));
    expect(document.querySelector('[role="dialog"]')).not.toBeNull();
    await act(async () => document.body.dispatchEvent(new Event("pointerdown", { bubbles: true })));
    expect(document.querySelector('[role="dialog"]')).toBeNull();
  });

  it("fits overshoot curves without bounding Y inputs", async () => {
    const input = document.querySelector<HTMLInputElement>('[aria-label="Motion/Curve Y2"]')!;
    expect(input.min).toBe("");
    expect(input.max).toBe("");
    const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    await act(async () => {
      setValue.call(input, "2");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    const handles = document.querySelectorAll(".bezier-handle");
    expect(Number(handles[1].getAttribute("cy"))).toBe(20);
    expect(changed).toHaveBeenLastCalledWith({ ...initial, y2: 2 });
  });

  it("keeps the viewport fixed during an overshoot drag and fits it on release", async () => {
    const graph = document.querySelector<SVGSVGElement>(".bezier-graph")!;
    const handles = document.querySelectorAll<SVGCircleElement>(".bezier-handle");
    Object.defineProperty(graph, "getScreenCTM", { value: () => ({ inverse: () => ({}) }) });
    Object.defineProperty(graph, "setPointerCapture", { value: vi.fn() });
    vi.stubGlobal(
      "DOMPoint",
      class {
        constructor(
          public x: number,
          public y: number
        ) {}
        matrixTransform() {
          return this;
        }
      }
    );
    const pointer = (type: string, y: number) =>
      Object.assign(new MouseEvent(type, { bubbles: true, button: 0, clientX: 68, clientY: y }), { pointerId: 1 });
    const initialFirstY = handles[0].getAttribute("cy");
    await act(async () => handles[1].dispatchEvent(pointer("pointerdown", 80)));
    await act(async () => graph.dispatchEvent(pointer("pointermove", -40)));
    expect(changed).toHaveBeenLastCalledWith({ ...initial, y2: 2 });
    await act(async () => graph.dispatchEvent(pointer("pointermove", -70)));
    expect(changed).toHaveBeenLastCalledWith({ ...initial, y2: 2.25 });
    expect(handles[0].getAttribute("cy")).toBe(initialFirstY);
    await act(async () => graph.dispatchEvent(pointer("pointerup", -70)));
    expect(Number(handles[1].getAttribute("cy"))).toBe(20);
    expect(handles[0].getAttribute("cy")).not.toBe(initialFirstY);
  });

  it("allows keyboard edits below zero on Y", async () => {
    const handle = document.querySelector('[role="button"]')!;
    await act(async () => handle.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })));
    expect(changed).toHaveBeenLastCalledWith({ ...initial, y1: -0.01 });
  });
});
