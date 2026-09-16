// @vitest-environment jsdom
import { afterEach, describe, expect, it, vi } from "vitest";
import { copyImageToClipboard } from "./imageActions";

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe("image clipboard formats", () => {
  it.each(["image/png"])("preserves %s and requests clipboard access before loading finishes", async (mimeType) => {
    const original = new Blob(["synthetic image"], { type: mimeType });
    let finishLoading!: (response: Response) => void;
    const response = new Promise<Response>((resolve) => {
      finishLoading = resolve;
    });
    vi.stubGlobal(
      "fetch",
      vi.fn(() => response)
    );
    vi.stubGlobal(
      "ClipboardItem",
      class {
        constructor(readonly data: Record<string, Promise<Blob>>) {}
        getType(type: string): Promise<Blob> {
          return this.data[type];
        }
      }
    );
    const write = vi.fn(async (items: ClipboardItem[]) => {
      expect(await items[0].getType(mimeType)).toBe(original);
    });
    vi.stubGlobal("navigator", { clipboard: { write } });

    const copying = copyImageToClipboard(`data:${mimeType};base64,AA==`, mimeType);

    expect(write).toHaveBeenCalledOnce();
    finishLoading({ blob: async () => original } as Response);
    await copying;
  });

  it.each(["image/jpeg", "image/webp", "image/gif"])(
    "converts %s to PNG after requesting clipboard access",
    async (mimeType) => {
      let finishDecode!: () => void;
      const decoded = new Promise<void>((resolve) => {
        finishDecode = resolve;
      });
      const image = document.createElement("img");
      image.decode = () => decoded;
      vi.stubGlobal(
        "Image",
        class {
          constructor() {
            return image;
          }
        }
      );
      vi.spyOn(HTMLImageElement.prototype, "naturalWidth", "get").mockReturnValue(16);
      vi.spyOn(HTMLImageElement.prototype, "naturalHeight", "get").mockReturnValue(8);
      const drawImage = vi.fn();
      vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockReturnValue({
        drawImage
      } as unknown as CanvasRenderingContext2D);
      const png = new Blob(["synthetic PNG"], { type: "image/png" });
      const toBlob = vi.spyOn(HTMLCanvasElement.prototype, "toBlob").mockImplementation(function (
        this: HTMLCanvasElement,
        callback,
        type
      ) {
        expect(this.width).toBe(16);
        expect(this.height).toBe(8);
        expect(type).toBe("image/png");
        callback(png);
      });
      vi.stubGlobal(
        "ClipboardItem",
        class {
          constructor(readonly data: Record<string, Promise<Blob>>) {}
          getType(type: string): Promise<Blob> {
            return this.data[type];
          }
        }
      );
      const write = vi.fn(async (items: ClipboardItem[]) => {
        expect(await items[0].getType("image/png")).toBe(png);
      });
      vi.stubGlobal("navigator", { clipboard: { write } });

      const copying = copyImageToClipboard(`data:${mimeType};base64,AA==`, mimeType);

      expect(write).toHaveBeenCalledOnce();
      expect(toBlob).not.toHaveBeenCalled();
      finishDecode();
      await copying;
      expect(drawImage).toHaveBeenCalledWith(expect.any(HTMLImageElement), 0, 0);
      expect(toBlob).toHaveBeenCalledOnce();
    }
  );
});
