import { readText } from "../http";

export class BodySearchHttpError extends Error {
  constructor(readonly status: number) {
    super(`Body search failed (${status}).`);
  }
}

export interface BodySearchMatch {
  terms: string[];
  complete: boolean;
  snippet?: string | null;
}
export interface RequestBodySearchMatch {
  requestId: string;
  request: BodySearchMatch;
  response: BodySearchMatch;
}
export interface BodySearchQuery {
  requestIds: string[];
  terms: string[];
}
export interface BodySearchReply {
  results: RequestBodySearchMatch[];
}

export const bodySearchLimits = {
  terms: 64,
  termLength: 256,
  requestIdLength: 512,
  batchSize: 8,
  snippetLength: 160,
  retryDelayMs: 500,
  timeoutMs: 30_000,
  replyBytes: 2 * 1024 * 1024
};

export function validBodySearchTerms(terms: readonly string[]): boolean {
  return (
    terms.length <= bodySearchLimits.terms &&
    terms.every((term) => term.length > 0 && term.length <= bodySearchLimits.termLength)
  );
}

export async function yieldSearch(signal: AbortSignal, delay = 0): Promise<void> {
  signal.throwIfAborted();
  await new Promise<void>((resolve) => setTimeout(resolve, delay));
  signal.throwIfAborted();
}

// Eight results fit below the reply limit even when every term needs JSON escaping.
export async function searchRemoteBodies(
  input: BodySearchQuery,
  signal: AbortSignal,
  sendBatch: (query: BodySearchQuery, signal: AbortSignal) => Promise<Response>,
  publish: (reply: BodySearchReply) => void = () => {}
): Promise<BodySearchReply> {
  if (
    !validBodySearchTerms(input.terms) ||
    input.requestIds.some((id) => !id.length || id.length > bodySearchLimits.requestIdLength)
  ) {
    throw new Error("Invalid body search query.");
  }
  const results: RequestBodySearchMatch[] = [];
  const requestIds = [...new Set(input.requestIds)];
  for (let offset = 0; offset < requestIds.length; ) {
    signal.throwIfAborted();
    const batch = { requestIds: requestIds.slice(offset, offset + bodySearchLimits.batchSize), terms: input.terms };
    let reply: BodySearchReply;
    try {
      reply = await readBodySearchReply(await sendBatch(batch, signal), batch);
    } catch (error) {
      signal.throwIfAborted();
      const retryable =
        error instanceof BodySearchHttpError
          ? error.status === 408 || error.status === 429 || error.status >= 500
          : error instanceof TypeError || (error instanceof DOMException && error.name === "TimeoutError");
      if (!retryable) break;
      await yieldSearch(signal, bodySearchLimits.retryDelayMs);
      continue;
    }
    signal.throwIfAborted();
    const accepted = { results: reply.results.filter((result) => batch.requestIds.includes(result.requestId)) };
    results.push(...accepted.results);
    publish(accepted);
    offset += batch.requestIds.length;
  }
  return { results };
}

async function readBodySearchReply(response: Response, input: BodySearchQuery): Promise<BodySearchReply> {
  if (!response.ok) throw new BodySearchHttpError(response.status);
  const result = JSON.parse(await readText(response, bodySearchLimits.replyBytes)) as BodySearchReply;
  if (
    !result ||
    !Array.isArray(result.results) ||
    result.results.some(
      (r) =>
        !r ||
        typeof r.requestId !== "string" ||
        [r.request, r.response].some(
          (body) =>
            !body ||
            (body.snippet != null &&
              (typeof body.snippet !== "string" || body.snippet.length > bodySearchLimits.snippetLength)) ||
            typeof body.complete !== "boolean" ||
            !Array.isArray(body.terms) ||
            body.terms.some((term) => typeof term !== "string" || !input.terms.includes(term))
        )
    )
  )
    throw new Error("Invalid body search response.");
  return result;
}
