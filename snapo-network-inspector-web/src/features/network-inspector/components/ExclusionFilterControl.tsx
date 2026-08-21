import { Plus, Settings2, X } from "lucide-react";
import { type FormEvent, useEffect, useId, useRef, useState } from "react";
import { normalizeExclusionFilter } from "../lib/exclusionFilters";

export function ExclusionFilterControl({
  exclusionFilters,
  hiddenRequestCount,
  onAddFilter,
  onRemoveFilter
}: {
  exclusionFilters: string[];
  hiddenRequestCount: number;
  onAddFilter(filter: string): void;
  onRemoveFilter(filter: string): void;
}): JSX.Element | null {
  const [expanded, setExpanded] = useState(false);
  const popupId = useId();
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!expanded) return;

    const closeOnOutsidePointer = (event: PointerEvent) => {
      if (!rootRef.current?.contains(event.target as Node)) setExpanded(false);
    };
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setExpanded(false);
    };

    window.addEventListener("pointerdown", closeOnOutsidePointer);
    window.addEventListener("keydown", closeOnEscape);
    return () => {
      window.removeEventListener("pointerdown", closeOnOutsidePointer);
      window.removeEventListener("keydown", closeOnEscape);
    };
  }, [expanded]);

  if (exclusionFilters.length === 0) return null;

  return (
    <div className="exclusion-filter-row" ref={rootRef}>
      <span className="exclusion-filter-summary">
        {hiddenRequestCount} {hiddenRequestCount === 1 ? "request" : "requests"} hidden
      </span>
      <button
        className="toolbar-icon-button exclusion-filter-settings"
        type="button"
        title="Manage permanent exclusion filters"
        aria-label="Manage permanent exclusion filters"
        aria-haspopup="dialog"
        aria-expanded={expanded}
        aria-controls={popupId}
        onClick={() => setExpanded((value) => !value)}
      >
        <Settings2 size={14} aria-hidden="true" />
      </button>

      {expanded ? (
        <ExclusionFilterPopover
          popupId={popupId}
          exclusionFilters={exclusionFilters}
          onAddFilter={onAddFilter}
          onRemoveFilter={onRemoveFilter}
        />
      ) : null}
    </div>
  );
}

export function ExclusionFilterPopover({
  popupId,
  exclusionFilters,
  onAddFilter,
  onRemoveFilter
}: {
  popupId: string;
  exclusionFilters: string[];
  onAddFilter(filter: string): void;
  onRemoveFilter(filter: string): void;
}): JSX.Element {
  const [filterText, setFilterText] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const normalizedFilter = normalizeExclusionFilter(filterText);
  const canAddFilter = normalizedFilter != null && !exclusionFilters.includes(normalizedFilter);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const addFilter = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (!canAddFilter || normalizedFilter == null) return;

    onAddFilter(normalizedFilter);
    setFilterText("");
    inputRef.current?.focus();
  };

  return (
    <div className="exclusion-filter-popup" id={popupId} role="dialog" aria-labelledby={`${popupId}-title`}>
      <div className="exclusion-filter-heading" id={`${popupId}-title`}>
        Exclusion filters
      </div>
      <p className="exclusion-filter-description">
        Exclude any matching text, or right-click a request to add its host to the exclusion filter. Filters are saved
        permanently.
      </p>

      <form className="exclusion-filter-form" onSubmit={addFilter}>
        <input
          ref={inputRef}
          value={filterText}
          onChange={(event) => setFilterText(event.target.value)}
          placeholder="Text to exclude"
          aria-label="Text to exclude"
          spellCheck={false}
          autoCapitalize="none"
          autoComplete="off"
        />
        <button
          className="toolbar-icon-button exclusion-filter-add"
          type="submit"
          disabled={!canAddFilter}
          aria-label="Add exclusion filter"
        >
          <Plus size={16} aria-hidden="true" />
        </button>
      </form>

      {exclusionFilters.length === 0 ? (
        <p className="exclusion-filter-empty">No exclusion filters</p>
      ) : (
        <ul className="exclusion-filter-list">
          {exclusionFilters.map((filter) => (
            <li className="exclusion-filter-item" key={filter}>
              <span className="exclusion-filter-expression">{filter.replace(/^-/, "- ")}</span>
              <button
                className="toolbar-icon-button exclusion-filter-remove"
                type="button"
                aria-label={`Remove ${filter}`}
                title={`Remove ${filter}`}
                onClick={() => onRemoveFilter(filter)}
              >
                <X size={14} aria-hidden="true" />
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
