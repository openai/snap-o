// @vitest-environment jsdom
import { createElement, render } from "preact";
import { act } from "preact/test-utils";
import { afterEach, expect, it, vi } from "vitest";
import { host } from "@snap-o/tool-host";
import type { TweakList, TweakValueDescriptor } from "../../types";
import type { TweaksClient } from "./client";
import { TweaksToolApp } from "./TweaksToolApp";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<T>((ok, fail) => {
    resolve = ok;
    reject = fail;
  });
  return { promise, resolve, reject };
}

const first = "Synthetic/First";
const second = "Synthetic/Second";
const descriptor = (name: string, value: string): TweakValueDescriptor => ({
  name,
  value,
  default: "original",
  type: "string",
  modified: value !== "original"
});
const snapshot = (a = "original", b = "original"): TweakList => ({
  tweaks: [descriptor(first, a), descriptor(second, b)]
});

async function mount() {
  vi.spyOn(host, "setToolbar").mockResolvedValue(undefined);
  const stale = deferred<TweakList>();
  const client: TweaksClient = {
    listTweaks: vi.fn().mockReturnValueOnce(stale.promise),
    updateTweaks: vi
      .fn()
      .mockResolvedValueOnce({ tweaks: [], errors: [{ name: first, error: "Synthetic rejection" }] }),
    subscribeTweaks: vi.fn((_connection, receive) => {
      receive(snapshot());
      return () => {};
    }),
    invokeTweakAction: vi.fn(),
    openExternal: vi.fn(),
    dispose: vi.fn()
  };
  const container = document.createElement("div");
  document.body.append(container);
  const connection = { processIdentity: "synthetic:1:2", signal: new AbortController().signal };
  await act(async () => {
    render(createElement(TweaksToolApp, { client, connection }), container);
  });
  const edit = async (name: string, value: string) => {
    const input = container.querySelector<HTMLInputElement>(`input[aria-label="${name}"]`)!;
    expect(input).not.toBeNull();
    await act(async () => {
      input.value = value;
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
  };
  const value = (name: string) => container.querySelector<HTMLInputElement>(`input[aria-label="${name}"]`)!.value;
  await edit(first, "rejected");
  expect(client.listTweaks).toHaveBeenCalledOnce();
  return { client, stale, container, edit, value };
}

afterEach(() => {
  for (const child of [...document.body.children]) {
    act(() => render(null, child));
    child.remove();
  }
  vi.restoreAllMocks();
});

it.each([first, second])("does not let an old rejection reload overwrite a successful edit to %s", async (name) => {
  const f = await mount();
  vi.mocked(f.client.updateTweaks).mockResolvedValueOnce({ tweaks: [{ name, value: "newest", modified: true }] });
  vi.mocked(f.client.listTweaks).mockResolvedValueOnce(
    name === first ? snapshot("newest") : snapshot("original", "newest")
  );
  await f.edit(name, "newest");
  expect(f.value(name)).toBe("newest");
  await act(async () => {
    f.stale.resolve(snapshot());
    await f.stale.promise;
  });
  expect(f.value(name)).toBe("newest");
  expect(f.value(first)).toBe(name === first ? "newest" : "original");
  expect(f.client.listTweaks).toHaveBeenCalledTimes(2);
});

it("retries a superseded reload failure without showing its obsolete error", async () => {
  const f = await mount();
  vi.mocked(f.client.updateTweaks).mockResolvedValueOnce({
    tweaks: [{ name: first, value: "newest", modified: true }]
  });
  vi.mocked(f.client.listTweaks).mockResolvedValueOnce(snapshot("newest"));
  await f.edit(first, "newest");
  await act(async () => {
    f.stale.reject(new Error("Obsolete reload failure"));
    await f.stale.promise.catch(() => {});
  });
  expect(f.value(first)).toBe("newest");
  expect(f.container.textContent).not.toContain("Obsolete reload failure");
  expect(f.client.listTweaks).toHaveBeenCalledTimes(2);
});

it("applies a current rejection reload without requesting another snapshot", async () => {
  const f = await mount();
  await act(async () => {
    f.stale.resolve(snapshot());
    await f.stale.promise;
  });
  expect(f.value(first)).toBe("original");
  expect(f.client.listTweaks).toHaveBeenCalledOnce();
});

it("keeps a current reload error visible", async () => {
  const f = await mount();
  await act(async () => {
    f.stale.reject(new Error("Current reload failure"));
    await f.stale.promise.catch(() => {});
  });
  expect(f.container.textContent).toContain("Current reload failure");
  expect(f.client.listTweaks).toHaveBeenCalledOnce();
});

it("does not retry a late response after unmounting", async () => {
  const f = await mount();
  act(() => render(null, f.container));
  await act(async () => {
    f.stale.resolve(snapshot());
    await f.stale.promise;
  });
  expect(f.client.listTweaks).toHaveBeenCalledOnce();
  expect(f.container.textContent).toBe("");
});
