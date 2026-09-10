// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { previewClient } from "./client";

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("synthetic preview client", () => {
  it("copies text through the browser clipboard", async () => {
    const writeText = vi.fn(async () => {});
    vi.stubGlobal("navigator", { clipboard: { writeText } });

    await previewClient.copyText("Synthetic payload");

    expect(writeText).toHaveBeenCalledWith("Synthetic payload");
  });

  it.each([
    { encoding: "utf8" as const, data: "demo", bytes: [100, 101, 109, 111] },
    { encoding: "base64" as const, data: "AAH/", bytes: [0, 1, 255] }
  ])("downloads $encoding data and releases its temporary URL", async ({ encoding, data, bytes }) => {
    const createObjectURL = vi.fn<(blob: Blob) => string>(() => "blob:preview-download");
    const revokeObjectURL = vi.fn();
    vi.stubGlobal("URL", { createObjectURL, revokeObjectURL });
    const click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function (this: HTMLAnchorElement) {
      expect(this.isConnected).toBe(true);
    });

    await expect(previewClient.saveFile({ encoding, data, defaultPath: "sample.bin" })).resolves.toEqual({
      saved: true
    });

    const download = click.mock.instances[0] as HTMLAnchorElement;
    expect(download.download).toBe("sample.bin");
    expect(download.href).toBe("blob:preview-download");
    expect(download.isConnected).toBe(false);
    expect(revokeObjectURL).toHaveBeenCalledWith("blob:preview-download");
    const blob = createObjectURL.mock.calls[0][0];
    const buffer = await new Promise<ArrayBuffer>((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result as ArrayBuffer);
      reader.onerror = () => reject(reader.error);
      reader.readAsArrayBuffer(blob);
    });
    expect([...new Uint8Array(buffer)]).toEqual(bytes);
  });
});
