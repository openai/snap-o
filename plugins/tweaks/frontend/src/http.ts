export async function readText(response: Response, limit: number): Promise<string> {
  if (!response.body) throw new Error("Empty tool response.");
  const reader = response.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let result = "";
  let bytes = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) return result + decoder.decode();
      bytes += value.length;
      if (bytes > limit) throw new Error("Tool response is too large.");
      result += decoder.decode(value, { stream: true });
    }
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
