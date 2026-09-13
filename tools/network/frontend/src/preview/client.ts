import type { ToolContentClient } from "../network/client";

export const previewClient: ToolContentClient = {
  copyText: (text) => navigator.clipboard.writeText(text),
  async saveFile(input) {
    const url = URL.createObjectURL(input.data);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = input.name;
    anchor.hidden = true;
    document.body.append(anchor);
    try {
      anchor.click();
    } finally {
      anchor.remove();
      URL.revokeObjectURL(url);
    }
    return true;
  }
};
