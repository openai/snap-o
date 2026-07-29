const hiddenHostsStorageKey = "snapo.networkInspector.hiddenHosts";

export class HiddenHostsRevision {
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

export function normalizeHiddenHost(value: string): string | null {
  const trimmed = value.trim().replace(/^\*\./, "");
  if (trimmed.length === 0) return null;

  try {
    const url = new URL(/^[a-z][a-z\d+.-]*:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`);
    if (!["http:", "https:", "ws:", "wss:"].includes(url.protocol)) return null;
    if (url.username.length > 0 || url.password.length > 0) return null;

    const hostname = url.hostname.toLowerCase().replace(/\.$/, "");
    return hostname.length === 0 ? null : hostname;
  } catch {
    return null;
  }
}

export function normalizeHiddenHosts(values: readonly string[]): string[] {
  return [...new Set(values.map(normalizeHiddenHost).filter((host): host is string => host != null))].sort();
}

export function isHiddenHost(url: string, hiddenHosts: readonly string[]): boolean {
  if (hiddenHosts.length === 0) return false;

  try {
    const hostname = new URL(url).hostname.toLowerCase().replace(/\.$/, "");
    return hiddenHosts.some((host) => hostname === host || hostname.endsWith(`.${host}`));
  } catch {
    return false;
  }
}

export function loadHiddenHosts(): string[] {
  try {
    const raw = window.localStorage.getItem(hiddenHostsStorageKey);
    if (raw == null) return [];

    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];

    return normalizeHiddenHosts(parsed.filter((value): value is string => typeof value === "string"));
  } catch {
    return [];
  }
}

export function saveHiddenHosts(hosts: readonly string[]): void {
  try {
    window.localStorage.setItem(hiddenHostsStorageKey, JSON.stringify(normalizeHiddenHosts(hosts)));
  } catch {
    // Keep network inspection usable when persistent storage is unavailable.
  }
}
