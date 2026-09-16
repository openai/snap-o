export async function copyImageToClipboard(dataUrl: string, mimeType: string): Promise<void> {
  const clipboardItem = window.ClipboardItem;
  if (clipboardItem == null) throw new Error("Image copying is unavailable.");
  // Start the clipboard write during the gesture, before the image finishes loading.
  const blob = mimeType === "image/png" ? fetch(dataUrl).then((response) => response.blob()) : imageAsPng(dataUrl);
  // WebKit exposes PNG to native apps; other image types remain WebKit-only data.
  await navigator.clipboard.write([new clipboardItem({ "image/png": blob })]);
}

async function imageAsPng(dataUrl: string): Promise<Blob> {
  const image = new Image();
  image.src = dataUrl;
  await image.decode();
  const canvas = document.createElement("canvas");
  canvas.width = image.naturalWidth;
  canvas.height = image.naturalHeight;
  const context = canvas.getContext("2d");
  if (context == null) throw new Error("Could not convert the image to PNG.");
  context.drawImage(image, 0, 0);
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (blob == null) reject(new Error("Could not convert the image to PNG."));
      else resolve(blob);
    }, "image/png");
  });
}

export function imageFileName(contentType: string | null): string {
  if (contentType?.startsWith("image/png") === true) return "image.png";
  if (contentType?.startsWith("image/jpeg") === true || contentType?.startsWith("image/jpg") === true)
    return "image.jpg";
  if (contentType?.startsWith("image/webp") === true) return "image.webp";
  if (contentType?.startsWith("image/gif") === true) return "image.gif";
  return "image";
}
