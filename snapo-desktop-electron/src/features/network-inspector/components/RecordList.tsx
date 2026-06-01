import { memo, useCallback, useEffect, useState, type MouseEvent, type UIEvent } from "react";
import type { NetworkClient } from "../../../network/client";
import { recordId, type InspectorRecord } from "../../../network/cdp";
import { ContextMenu, type ContextMenuItem, type ContextMenuState } from "./ContextMenu";
import { StatusView } from "./Status";
import { copyCurl, exportAsHar } from "../lib/exportActions";
import { contextMenuExportSelection, splitUrl } from "../lib/records";
import { HighlightText } from "./SearchHighlight";

export const RecordList = memo(function RecordList({
  records,
  allRecords,
  placeholder,
  selectedRecordId,
  onSelect,
  client,
  searchText
}: {
  records: InspectorRecord[];
  allRecords: InspectorRecord[];
  placeholder: string | null;
  selectedRecordId: string | null;
  onSelect(id: string): void;
  client: NetworkClient;
  searchText: string;
}): JSX.Element {
  const [menu, setMenu] = useState<ContextMenuState | null>(null);
  const [showTopFade, setShowTopFade] = useState(false);
  const handleContextMenu = useCallback(
    (record: InspectorRecord, event: MouseEvent) => {
      const id = recordId(record);
      event.preventDefault();
      onSelect(id);
      setMenu({
        x: event.clientX,
        y: event.clientY,
        items: sidebarContextMenuItems(record, selectedRecordId, allRecords, client)
      });
    },
    [allRecords, client, onSelect, selectedRecordId]
  );

  useEffect(() => {
    if (menu == null) return;
    const close = () => setMenu(null);
    window.addEventListener("pointerdown", close);
    window.addEventListener("keydown", close);
    return () => {
      window.removeEventListener("pointerdown", close);
      window.removeEventListener("keydown", close);
    };
  }, [menu]);

  if (placeholder != null) return <div className="sidebar-placeholder">{placeholder}</div>;

  return (
    <div className="record-list-frame">
      <div className="record-list" onScroll={(event) => handleRecordListScroll(event, setShowTopFade)}>
        {records.map((record) => {
          const id = recordId(record);
          return (
            <RecordRow
              key={id}
              id={id}
              record={record}
              selected={selectedRecordId === id}
              onSelect={onSelect}
              onContextMenu={handleContextMenu}
              searchText={searchText}
            />
          );
        })}
      </div>
      <div className={showTopFade ? "record-list-top-fade visible" : "record-list-top-fade"} />
      {menu == null ? null : <ContextMenu menu={menu} onClose={() => setMenu(null)} />}
    </div>
  );
});

function handleRecordListScroll(event: UIEvent<HTMLDivElement>, setShowTopFade: (value: boolean) => void): void {
  setShowTopFade(event.currentTarget.scrollTop > 0);
}

const RecordRow = memo(function RecordRow({
  id,
  record,
  selected,
  onSelect,
  onContextMenu,
  searchText
}: {
  id: string;
  record: InspectorRecord;
  selected: boolean;
  onSelect(id: string): void;
  onContextMenu(record: InspectorRecord, event: MouseEvent): void;
  searchText: string;
}): JSX.Element {
  const path = splitUrl(record.url);
  return (
    <button
      type="button"
      className={`record-row ${selected ? "selected" : ""}`}
      onClick={() => onSelect(id)}
      onContextMenu={(event) => onContextMenu(record, event)}
    >
      <span className="record-main">
        <span className="record-primary">
          <HighlightText text={path.primary} searchText={searchText} />
        </span>
        <span className="record-secondary">
          <HighlightText text={path.secondary} searchText={searchText} />
        </span>
      </span>
      <span className="record-method">
        <HighlightText text={record.method} searchText={searchText} />
      </span>
      <StatusView record={record} searchText={searchText} />
    </button>
  );
});

function sidebarContextMenuItems(
  clicked: InspectorRecord,
  selectedRecordId: string | null,
  allRecords: InspectorRecord[],
  client: NetworkClient
): ContextMenuItem[] {
  const exportRecords = contextMenuExportSelection(clicked, selectedRecordId, allRecords);
  const items: ContextMenuItem[] = [
    { label: "Copy URL", action: () => void navigator.clipboard.writeText(clicked.url) }
  ];
  if (clicked.kind === "request") {
    items.push({ label: "Copy as cURL", action: () => void copyCurl(client, clicked) });
  }
  items.push({ label: "Export HAR (sanitized)...", action: () => void exportAsHar(client, exportRecords) });
  return items;
}
