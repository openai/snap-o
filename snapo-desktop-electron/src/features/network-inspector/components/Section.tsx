import type { ReactNode } from "react";
import type { PersistentInspectorUiState } from "../hooks/usePersistentInspectorUiState";

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
  uiState: PersistentInspectorUiState;
  initiallyExpanded?: boolean;
  trailing?: ReactNode;
  children: ReactNode;
}): JSX.Element {
  const expanded = uiState.sectionExpanded(storageKey, initiallyExpanded);
  return (
    <section className="detail-section">
      <div className="section-header-row">
        <button className="section-header" type="button" onClick={() => uiState.setSectionExpanded(storageKey, !expanded)}>
          <span className={expanded ? "triangle expanded" : "triangle"} />
          <span>{title}</span>
          {meta == null ? null : <span className="section-meta">{meta}</span>}
        </button>
        {trailing}
      </div>
      {expanded ? children : null}
    </section>
  );
}

export function HeadersTable({ headers }: { headers: Array<{ name: string; value: string }> }): JSX.Element {
  if (headers.length === 0) return <div className="headers-empty">None</div>;
  return (
    <div className="headers-grid">
      {headers.map((header, index) => (
        <div className="header-row" key={`${header.name}:${index}`}>
          <span className="header-name"> {header.name}:</span>
          <span className="header-value">  {header.value}</span>
        </div>
      ))}
    </div>
  );
}
