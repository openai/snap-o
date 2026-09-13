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

  it("downloads a Blob and releases its temporary URL", async () => {
    const createObjectURL = vi.fn<(blob: Blob) => string>(() => "blob:preview-download");
    const revokeObjectURL = vi.fn();
    vi.stubGlobal("URL", { createObjectURL, revokeObjectURL });
    const click = vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(function (this: HTMLAnchorElement) {
      expect(this.isConnected).toBe(true);
    });

    const data = new Blob([new Uint8Array([0, 1, 255])], { type: "image/png" });
    await expect(previewClient.saveFile({ data, name: "sample.png" })).resolves.toBe(true);
    expect(createObjectURL).toHaveBeenCalledWith(data);

    const download = click.mock.instances[0] as HTMLAnchorElement;
    expect(download.download).toBe("sample.png");
    expect(download.href).toBe("blob:preview-download");
    expect(download.isConnected).toBe(false);
    expect(revokeObjectURL).toHaveBeenCalledWith("blob:preview-download");
  });
});
