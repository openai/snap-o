import { describe, expect, it } from "vitest";
import {
  ExclusionFiltersRevision,
  exclusionFilterForUrl,
  normalizeExclusionFilter,
  normalizeExclusionFilters
} from "./exclusionFilters";

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
});
