import type { ClipboardEvent, ReactNode } from "react";
import type { InspectorUiState } from "../hooks/useInspectorUiState";

export function Section({
  title,
  meta,
  storageKey,
  uiState,
  initiallyExpanded = true,
  trailing,
  children
}: {
  title: string;
  meta?: string | null;
  storageKey: string;
  uiState: InspectorUiState;
  initiallyExpanded?: boolean;
  trailing?: ReactNode;
  children: ReactNode;
}): JSX.Element {
  const expanded = uiState.sectionExpanded(storageKey, initiallyExpanded);
  return (
    <section className="detail-section">
      <div className="section-header-row">
        <button
          className="section-header"
          type="button"
          onClick={() => uiState.setSectionExpanded(storageKey, !expanded)}
        >
          <span className="section-triangle-slot">
            <span className={expanded ? "triangle expanded" : "triangle"} />
          </span>
          <span>{title}</span>
          {meta == null ? null : <span className="section-meta">{meta}</span>}
        </button>
        {trailing}
      </div>
      {expanded ? children : null}
    </section>
  );
}

interface HeaderRow {
  name: string;
  value: string;
}

export function HeadersTable({ headers }: { headers: HeaderRow[] }): JSX.Element {
  if (headers.length === 0) return <div className="headers-empty">None</div>;
  return (
    <div className="headers-grid" onCopy={(event) => copyHeaders(event, headers)}>
      {headers.map((header, index) => (
        <div className="header-row" data-header-index={index} key={`${header.name}:${index}`}>
          <span className="header-name">{header.name}:</span>
          <span className="header-value">{header.value}</span>
        </div>
      ))}
    </div>
  );
}

function copyHeaders(event: ClipboardEvent<HTMLDivElement>, headers: HeaderRow[]): void {
  const selectedHeaders = selectedHeaderRows(event.currentTarget, headers);
  const copiedHeaders = selectedHeaders.length > 0 ? selectedHeaders : headers;
  event.clipboardData.setData("text/plain", copiedHeaders.map(formatHeaderLine).join("\n"));
  event.preventDefault();
}

function selectedHeaderRows(container: HTMLDivElement, headers: HeaderRow[]): HeaderRow[] {
  const selection = window.getSelection();
  if (selection == null || selection.rangeCount === 0 || selection.isCollapsed) return [];

  const rows = Array.from(container.querySelectorAll<HTMLElement>("[data-header-index]"));
  const selected: HeaderRow[] = [];
  for (const row of rows) {
    const index = Number(row.dataset.headerIndex);
    if (!Number.isInteger(index)) continue;
    if (headers[index] == null) continue;
    if (selectionIntersectsNode(selection, row)) selected.push(headers[index]);
  }
  return selected;
}

function selectionIntersectsNode(selection: Selection, node: Node): boolean {
  for (let index = 0; index < selection.rangeCount; index += 1) {
    const range = selection.getRangeAt(index);
    if (range.intersectsNode(node)) return true;
  }
  return false;
}

function formatHeaderLine(header: HeaderRow): string {
  return `${header.name}: ${header.value}`;
}
