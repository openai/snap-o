import type { ToolContentClient } from "../network/client";

export const previewClient: ToolContentClient = {
  copyText: (text) => navigator.clipboard.writeText(text),
  async saveFile(input) {
    const data =
      input.encoding === "base64" ? Uint8Array.from(atob(input.data), (char) => char.charCodeAt(0)) : input.data;
    const url = URL.createObjectURL(new Blob([data], { type: input.mimeType ?? "application/octet-stream" }));
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = input.defaultPath;
    anchor.hidden = true;
    document.body.append(anchor);
    try {
      anchor.click();
    } finally {
      anchor.remove();
      URL.revokeObjectURL(url);
    }
    return { saved: true };
  }
};
