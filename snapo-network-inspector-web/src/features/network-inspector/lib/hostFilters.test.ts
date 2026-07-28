import { afterEach, describe, expect, it, vi } from "vitest";
import {
  isHiddenHost,
  loadHiddenHosts,
  normalizeHiddenHost,
  normalizeHiddenHosts,
  saveHiddenHosts
} from "./hostFilters";

afterEach(() => vi.unstubAllGlobals());

describe("persistent hidden host filters", () => {
  it("normalizes host names, URLs, ports, and wildcard prefixes", () => {
    expect(normalizeHiddenHost("  API.Example.COM  ")).toBe("api.example.com");
    expect(normalizeHiddenHost("https://API.Example.COM:443/events")).toBe("api.example.com");
    expect(normalizeHiddenHost("*.example.com")).toBe("example.com");
    expect(normalizeHiddenHost("wss://socket.example.com/live")).toBe("socket.example.com");
  });

  it("rejects blank hosts, unsupported schemes, and embedded credentials", () => {
    expect(normalizeHiddenHost("  ")).toBeNull();
    expect(normalizeHiddenHost("file:///tmp/events")).toBeNull();
    expect(normalizeHiddenHost("https://user:password@example.com")).toBeNull();
    expect(normalizeHiddenHost("not a valid host")).toBeNull();
  });

  it("deduplicates and sorts equivalent host filters", () => {
    expect(normalizeHiddenHosts(["Statsig.com", "https://statsig.com/events", "api.example.com", ""])).toEqual([
      "api.example.com",
      "statsig.com"
    ]);
  });

  it("hides the exact host and its subdomains without hiding similarly named hosts", () => {
    const hiddenHosts = ["example.com"];

    expect(isHiddenHost("https://example.com/events", hiddenHosts)).toBe(true);
    expect(isHiddenHost("https://api.example.com/events", hiddenHosts)).toBe(true);
    expect(isHiddenHost("wss://stream.api.example.com/socket", hiddenHosts)).toBe(true);
    expect(isHiddenHost("https://notexample.com/events", hiddenHosts)).toBe(false);
    expect(isHiddenHost("not a url", hiddenHosts)).toBe(false);
  });

  it("restores and normalizes hosts saved in browser storage", () => {
    const values = new Map<string, string>();
    vi.stubGlobal("window", {
      localStorage: {
        getItem: (key: string) => values.get(key) ?? null,
        setItem: (key: string, value: string) => values.set(key, value)
      }
    });

    saveHiddenHosts(["API.Example.COM", "https://api.example.com/events", "statsig.com"]);

    expect(loadHiddenHosts()).toEqual(["api.example.com", "statsig.com"]);
  });

  it("keeps the inspector usable when persistent storage is unavailable", () => {
    vi.stubGlobal("window", {
      localStorage: {
        getItem: () => {
          throw new Error("Storage is unavailable");
        },
        setItem: () => {
          throw new Error("Storage is unavailable");
        }
      }
    });

    expect(loadHiddenHosts()).toEqual([]);
    expect(() => saveHiddenHosts(["example.com"])).not.toThrow();
  });
});
