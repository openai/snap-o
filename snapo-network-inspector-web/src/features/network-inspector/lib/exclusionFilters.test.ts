import { afterEach, describe, expect, it, vi } from "vitest";
import {
  ExclusionFiltersRevision,
  exclusionFilterForUrl,
  loadExclusionFilters,
  normalizeExclusionFilter,
  normalizeExclusionFilters,
  saveExclusionFilters
} from "./exclusionFilters";

afterEach(() => vi.unstubAllGlobals());

describe("persistent Snap-O exclusion filters", () => {
  it("rejects startup snapshots after a newer exclusion-filter update", () => {
    const revision = new ExclusionFiltersRevision();
    const startupSnapshot = revision.capture();

    revision.invalidate();

    expect(revision.isCurrent(startupSnapshot)).toBe(false);
    expect(revision.isCurrent(revision.capture())).toBe(true);
  });

  it("rejects a failed mutation's recovery after a newer exclusion-filter update", () => {
    const revision = new ExclusionFiltersRevision();

    revision.invalidate();
    const recoverySnapshot = revision.capture();
    revision.invalidate();

    expect(revision.isCurrent(recoverySnapshot)).toBe(false);
  });

  it("stores exclusions in the same minus-prefixed syntax as regular Snap-O filters", () => {
    expect(normalizeExclusionFilter("  API.Example.COM  ")).toBe("-api.example.com");
    expect(normalizeExclusionFilter("-API.Example.COM")).toBe("-api.example.com");
    expect(normalizeExclusionFilter("event stream")).toBe('-"event stream"');
    expect(normalizeExclusionFilter('-"EVENT STREAM"')).toBe('-"event stream"');
  });

  it("rejects empty values and expressions with more than one filter", () => {
    expect(normalizeExclusionFilter("  ")).toBeNull();
    expect(normalizeExclusionFilter("-")).toBeNull();
    expect(normalizeExclusionFilter("-example.com visible")).toBeNull();
  });

  it("deduplicates and sorts equivalent exclusion filters", () => {
    expect(normalizeExclusionFilters(["Statsig.com", "-statsig.com", "api.example.com", ""])).toEqual([
      "-api.example.com",
      "-statsig.com"
    ]);
  });

  it("builds a conventional host exclusion from HTTP and WebSocket URLs", () => {
    expect(exclusionFilterForUrl("https://API.Example.COM:443/events")).toBe("-api.example.com");
    expect(exclusionFilterForUrl("wss://stream.example.com/live")).toBe("-stream.example.com");
    expect(exclusionFilterForUrl("file:///tmp/events")).toBeNull();
    expect(exclusionFilterForUrl("https://user:password@example.com")).toBeNull();
    expect(exclusionFilterForUrl("not a url")).toBeNull();
  });

  it("restores and normalizes exclusion filters saved in browser storage", () => {
    const values = new Map<string, string>();
    vi.stubGlobal("window", {
      localStorage: {
        getItem: (key: string) => values.get(key) ?? null,
        setItem: (key: string, value: string) => values.set(key, value)
      }
    });

    saveExclusionFilters(["API.Example.COM", "-api.example.com", "statsig.com"]);

    expect(loadExclusionFilters()).toEqual(["-api.example.com", "-statsig.com"]);
    expect(values.get("snapo.networkInspector.exclusionFilters")).toBe('["-api.example.com","-statsig.com"]');
  });

  it("migrates previously saved hosts to regular exclusion filters", () => {
    vi.stubGlobal("window", {
      localStorage: {
        getItem: (key: string) =>
          key === "snapo.networkInspector.hiddenHosts" ? '["API.Example.COM","statsig.com"]' : null
      }
    });

    expect(loadExclusionFilters()).toEqual(["-api.example.com", "-statsig.com"]);
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

    expect(loadExclusionFilters()).toEqual([]);
    expect(() => saveExclusionFilters(["-example.com"])).not.toThrow();
  });
});
