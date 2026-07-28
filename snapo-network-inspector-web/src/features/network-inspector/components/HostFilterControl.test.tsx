import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { HostFilterPopover } from "./HostFilterControl";

describe("hidden host filter popup", () => {
  it("explains how to add a host from the request context menu", () => {
    const markup = renderToStaticMarkup(
      <HostFilterPopover popupId="hidden-hosts" hiddenHosts={[]} onRemoveHost={vi.fn()} />
    );

    expect(markup).toContain("Right-click on any request and click");
    expect(markup).toContain("Add to filtered hosts");
    expect(markup).toContain("No hidden hosts");
  });

  it("does not offer a host input or add action in the popup", () => {
    const markup = renderToStaticMarkup(
      <HostFilterPopover popupId="hidden-hosts" hiddenHosts={[]} onRemoveHost={vi.fn()} />
    );

    expect(markup).not.toContain("<form");
    expect(markup).not.toContain("<input");
    expect(markup).not.toContain("Add hidden host");
  });

  it("shows the filtered hosts and lets each host be removed", () => {
    const markup = renderToStaticMarkup(
      <HostFilterPopover
        popupId="hidden-hosts"
        hiddenHosts={["api.example.com", "statsig.com"]}
        onRemoveHost={vi.fn()}
      />
    );

    expect(markup).toContain("api.example.com");
    expect(markup).toContain("statsig.com");
    expect(markup).toContain('aria-label="Show api.example.com again"');
    expect(markup).toContain('aria-label="Show statsig.com again"');
  });
});
