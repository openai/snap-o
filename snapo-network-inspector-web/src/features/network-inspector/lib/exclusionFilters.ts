import { parseKeywordSearchQuery } from "../../../network/keyword-search";

const exclusionFiltersStorageKey = "snapo.networkInspector.exclusionFilters";
const legacyHiddenHostsStorageKey = "snapo.networkInspector.hiddenHosts";

export class ExclusionFiltersRevision {
  private value = 0;

  capture(): number {
    return this.value;
  }

  invalidate(): void {
    this.value += 1;
  }

  isCurrent(revision: number): boolean {
    return this.value === revision;
  }
}

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

export function loadExclusionFilters(): string[] {
  try {
    const raw = window.localStorage.getItem(exclusionFiltersStorageKey);
    if (raw == null) return loadLegacyHiddenHosts();

    return parseStoredFilters(raw);
  } catch {
    return [];
  }
}

export function saveExclusionFilters(filters: readonly string[]): void {
  try {
    window.localStorage.setItem(exclusionFiltersStorageKey, JSON.stringify(normalizeExclusionFilters(filters)));
  } catch {
    // Keep network inspection usable when persistent storage is unavailable.
  }
}

function loadLegacyHiddenHosts(): string[] {
  try {
    const raw = window.localStorage.getItem(legacyHiddenHostsStorageKey);
    if (raw == null) return [];

    return parseStoredFilters(raw);
  } catch {
    return [];
  }
}

function parseStoredFilters(raw: string): string[] {
  const parsed: unknown = JSON.parse(raw);
  if (!Array.isArray(parsed)) return [];

  return normalizeExclusionFilters(parsed.filter((value): value is string => typeof value === "string"));
}

function exclusionExpression(value: string): string {
  const normalized = value.toLowerCase();
  if (!/[\s"\\]/u.test(normalized)) return `-${normalized}`;

  const escaped = normalized.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  return `-"${escaped}"`;
}
