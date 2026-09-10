// @vitest-environment jsdom
import { render } from "preact";
import { act } from "preact/test-utils";
import { renderToStaticMarkup } from "preact-render-to-string";
import { describe, expect, it, vi } from "vitest";
import { ExclusionFilterControl, ExclusionFilterPopover } from "./ExclusionFilterControl";

describe("persistent exclusion filter controls", () => {
  it("updates the filter on input and restores focus after submitting", async () => {
    const container = document.createElement("div");
    const onAddFilter = vi.fn();
    document.body.append(container);
    try {
      await act(() =>
        render(
          <ExclusionFilterPopover
            popupId="exclusions"
            exclusionFilters={[]}
            onAddFilter={onAddFilter}
            onRemoveFilter={vi.fn()}
          />,
          container
        )
      );
      const input = container.querySelector("input")!;
      const button = container.querySelector<HTMLButtonElement>('button[type="submit"]')!;
      expect(button.disabled).toBe(true);
      await act(() => {
        input.value = "api.example.test";
        input.dispatchEvent(new Event("input", { bubbles: true }));
      });
      expect(button.disabled).toBe(false);
      await act(() => button.click());
      expect(onAddFilter).toHaveBeenCalledExactlyOnceWith("-api.example.test");
      expect(input.value).toBe("");
      expect(document.activeElement).toBe(input);
    } finally {
      await act(() => render(null, container));
      container.remove();
    }
  });

  it("shows a subtle hidden-request summary and settings control without an attention badge", () => {
    const markup = renderToStaticMarkup(
      <ExclusionFilterControl
        exclusionFilters={["-api.example.com", "-statsig.com"]}
        hiddenRequestCount={3}
        onAddFilter={vi.fn()}
        onRemoveFilter={vi.fn()}
      />
    );

    expect(markup).toContain("3 requests hidden");
    expect(markup).toContain('aria-label="Manage permanent exclusion filters"');
    expect(markup).not.toContain("host-filter-count");
    expect(markup).not.toContain("host-filter-active");
  });

  it("uses the singular form for one hidden request", () => {
    const markup = renderToStaticMarkup(
      <ExclusionFilterControl
        exclusionFilters={["-api.example.com"]}
        hiddenRequestCount={1}
        onAddFilter={vi.fn()}
        onRemoveFilter={vi.fn()}
      />
    );

    expect(markup).toContain("1 request hidden");
  });

  it("does not show a settings row when no permanent exclusions exist", () => {
    const markup = renderToStaticMarkup(
      <ExclusionFilterControl
        exclusionFilters={[]}
        hiddenRequestCount={0}
        onAddFilter={vi.fn()}
        onRemoveFilter={vi.fn()}
      />
    );

    expect(markup).toBe("");
  });

  it("accepts any searchable text and explains how to exclude a request's host", () => {
    const markup = renderToStaticMarkup(
      <ExclusionFilterPopover
        popupId="exclusions"
        exclusionFilters={[]}
        onAddFilter={vi.fn()}
        onRemoveFilter={vi.fn()}
      />
    );

    expect(markup).toContain("right-click a request to add its host to the exclusion filter");
    expect(markup).toContain("Exclude any matching text");
    expect(markup).toContain("Filters are saved permanently");
    expect(markup).toContain("No exclusion filters");
    expect(markup).toContain('placeholder="Text to exclude"');
    expect(markup).toContain('aria-label="Add exclusion filter"');
  });

  it("shows the conventional exclusion expressions and lets each be removed", () => {
    const markup = renderToStaticMarkup(
      <ExclusionFilterPopover
        popupId="exclusions"
        exclusionFilters={["-api.example.com", "-statsig.com"]}
        onAddFilter={vi.fn()}
        onRemoveFilter={vi.fn()}
      />
    );

    expect(markup).toContain("- api.example.com");
    expect(markup).toContain("- statsig.com");
    expect(markup).toContain('aria-label="Remove -api.example.com"');
    expect(markup).toContain('aria-label="Remove -statsig.com"');
  });
});
