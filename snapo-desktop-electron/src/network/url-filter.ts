export interface UrlFilterTokens {
  includes: string[];
  excludes: string[];
}

export function matchesUrlFilterText(url: string, searchText: string): boolean {
  return matchesUrlFilter(url, parseUrlFilterTokens(searchText));
}

export function matchesUrlFilter(url: string, tokens: UrlFilterTokens): boolean {
  if (tokens.includes.length === 0 && tokens.excludes.length === 0) return true;
  const normalizedUrl = url.toLowerCase();
  return (
    tokens.includes.every((token) => normalizedUrl.includes(token)) &&
    !tokens.excludes.some((token) => normalizedUrl.includes(token))
  );
}

export function parseUrlFilterTokens(searchText: string): UrlFilterTokens {
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

      const escaped = escapedUrlFilterCharacter(searchText, index, quoted);
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

function escapedUrlFilterCharacter(text: string, index: number, quoted: boolean): string | null {
  if (text[index] !== "\\") return null;
  const next = text[index + 1];
  if (next == null) return null;
  if (next === '"' || next === "\\") return next;
  return !quoted && isWhitespace(next) ? next : null;
}

function isWhitespace(value: string): boolean {
  return /\s/u.test(value);
}
