import { parseKeywordSearchQuery } from "../../../network/keyword-search";

export function normalizeExclusionFilter(value: string): string | null {
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;

  const expression = trimmed.startsWith("-") ? trimmed : exclusionExpression(trimmed);
  const query = parseKeywordSearchQuery(expression);
  if (query.includes.length !== 0 || query.excludes.length !== 1) return null;
  return exclusionExpression(query.excludes[0]);
}

export function normalizeExclusionFilters(values: readonly string[]): string[] {
  return [...new Set(values.map(normalizeExclusionFilter).filter((filter): filter is string => filter != null))].sort();
}

export function exclusionFilterForUrl(value: string): string | null {
  try {
    const url = new URL(value);
    if (!["http:", "https:", "ws:", "wss:"].includes(url.protocol)) return null;
    if (url.username.length > 0 || url.password.length > 0) return null;

    const hostname = url.hostname.toLowerCase().replace(/\.$/, "");
    return hostname.length === 0 ? null : exclusionExpression(hostname);
  } catch {
    return null;
  }
}

function exclusionExpression(value: string): string {
  const normalized = value.toLowerCase();
  if (!/[\s"\\]/u.test(normalized)) return `-${normalized}`;

  const escaped = normalized.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  return `-"${escaped}"`;
}
