export interface KeywordSearchQuery {
  includes: string[];
  excludes: string[];
}

export interface KeywordSearchDocument {
  parts: string[];
}

export interface SearchHighlightRange {
  start: number;
  end: number;
}

export function parseKeywordSearchQuery(searchText: string): KeywordSearchQuery {
  const includes: string[] = [];
  const excludes: string[] = [];
  let index = 0;

  while (index < searchText.length) {
    while (index < searchText.length && isWhitespace(searchText[index])) index += 1;
    if (index >= searchText.length) break;

    const isExcluded = searchText[index] === "-";
    if (isExcluded) index += 1;
    if (index >= searchText.length) break;

    const quoted = searchText[index] === '"';
    if (quoted) index += 1;

    let value = "";
    while (index < searchText.length) {
      const current = searchText[index];
      if (quoted && current === '"') {
        index += 1;
        break;
      }
      if (!quoted && isWhitespace(current)) break;

      const escaped = escapedSearchCharacter(searchText, index, quoted);
      if (escaped != null) {
        value += escaped;
        index += 2;
      } else {
        value += current;
        index += 1;
      }
    }

    if (value.trim().length === 0) continue;
    (isExcluded ? excludes : includes).push(value.toLowerCase());
  }

  return { includes, excludes };
}

export function matchesKeywordSearchDocument(document: KeywordSearchDocument, query: KeywordSearchQuery): boolean {
  if (query.includes.length === 0 && query.excludes.length === 0) return true;
  const searchableText = document.parts.join("\n").toLowerCase();
  return (
    query.includes.every((token) => searchableText.includes(token)) &&
    !query.excludes.some((token) => searchableText.includes(token))
  );
}

export function searchHighlightRanges(text: string, query: KeywordSearchQuery): SearchHighlightRange[] {
  if (text.length === 0 || query.includes.length === 0) return [];

  const lowerText = text.toLowerCase();
  const candidates: SearchHighlightRange[] = [];
  for (const token of new Set(query.includes)) {
    if (token.length === 0) continue;
    let index = lowerText.indexOf(token);
    while (index !== -1) {
      candidates.push({ start: index, end: index + token.length });
      index = lowerText.indexOf(token, index + 1);
    }
  }

  candidates.sort((left, right) => left.start - right.start || right.end - left.end);
  const ranges: SearchHighlightRange[] = [];
  for (const candidate of candidates) {
    const previous = ranges.at(-1);
    if (previous != null && candidate.start < previous.end) continue;
    ranges.push(candidate);
  }
  return ranges;
}

function escapedSearchCharacter(text: string, index: number, quoted: boolean): string | null {
  if (text[index] !== "\\") return null;
  const next = text[index + 1];
  if (next == null) return null;
  if (next === '"' || next === "\\") return next;
  return !quoted && isWhitespace(next) ? next : null;
}

function isWhitespace(value: string): boolean {
  return /\s/u.test(value);
}
