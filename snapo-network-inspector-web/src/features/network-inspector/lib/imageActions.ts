export async function copyImageToClipboard(dataUrl: string, mimeType: string): Promise<void> {
  const clipboardItem = window.ClipboardItem;
  if (clipboardItem == null) return;
  const response = await fetch(dataUrl);
  const blob = await response.blob();
  await navigator.clipboard.write([new clipboardItem({ [mimeType]: blob })]);
}

export function imageFileName(contentType: string | null): string {
  if (contentType?.startsWith("image/png") === true) return "image.png";
  if (contentType?.startsWith("image/jpeg") === true || contentType?.startsWith("image/jpg") === true)
    return "image.jpg";
  if (contentType?.startsWith("image/webp") === true) return "image.webp";
  if (contentType?.startsWith("image/gif") === true) return "image.gif";
  return "image";
}
