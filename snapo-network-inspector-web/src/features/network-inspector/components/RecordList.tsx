import {
  memo,
  useCallback,
  useEffect,
  useId,
  useRef,
  useState,
  type KeyboardEvent,
  type MouseEvent,
  type UIEvent
} from "react";
import type { NetworkClient } from "../../../network/client";
import { recordId, type InspectorRecord } from "../../../network/cdp";
import { ContextMenu, type ContextMenuItem, type ContextMenuState } from "./ContextMenu";
import { StatusView } from "./Status";
import { copyCurl, exportAsHar } from "../lib/exportActions";
import { exclusionFilterForUrl } from "../lib/exclusionFilters";
import { contextMenuExportSelection, splitUrl } from "../lib/records";

export const RecordList = memo(function RecordList({
  records,
  allRecords,
  placeholder,
  selectedRecordId,
  onSelect,
  onAddExclusionFilter,
  client,
  isConnected = true
}: {
  records: InspectorRecord[];
  allRecords: InspectorRecord[];
  placeholder: string | null;
  selectedRecordId: string | null;
  onSelect(id: string): void;
  onAddExclusionFilter(value: string): void;
  client: NetworkClient;
  isConnected?: boolean;
}): JSX.Element {
  const listId = useId();
  const listRef = useRef<HTMLDivElement>(null);
  const selectedIndex = records.findIndex((record) => recordId(record) === selectedRecordId);
  const [menu, setMenu] = useState<(ContextMenuState & { keyboard: boolean }) | null>(null);
  const [showTopFade, setShowTopFade] = useState(false);
  const selectRecord = useCallback(
    (id: string) => {
      // WebKit does not always focus buttons on click. Keep keyboard ownership on the list.
      listRef.current?.focus({ preventScroll: true });
      onSelect(id);
    },
    [onSelect]
  );
  const openContextMenu = useCallback(
    (record: InspectorRecord, x: number, y: number, keyboard: boolean) => {
      selectRecord(recordId(record));
      setMenu({
        x,
        y,
        keyboard,
        items: sidebarContextMenuItems(record, selectedRecordId, allRecords, client, onAddExclusionFilter, isConnected)
      });
    },
    [allRecords, client, isConnected, onAddExclusionFilter, selectRecord, selectedRecordId]
  );
  const openActiveContextMenu = () => {
    const record = records[selectedIndex];
    const row = listRef.current?.children.item(selectedIndex);
    if (record == null || row == null) return false;
    row.scrollIntoView({ block: "nearest" });
    const { left, bottom } = row.getBoundingClientRect();
    openContextMenu(record, left, bottom, true);
    return true;
  };
  const closeContextMenu = () => {
    setMenu(null);
    listRef.current?.focus({ preventScroll: true });
  };
  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (event.defaultPrevented || event.nativeEvent.isComposing || event.altKey || event.ctrlKey || event.metaKey)
      return;
    if (event.key === "ContextMenu" || (event.key === "F10" && event.shiftKey)) {
      if (openActiveContextMenu()) {
        event.preventDefault();
        event.stopPropagation();
      }
      return;
    }
    if (event.shiftKey) return;
    if (records.length === 0) return;

    let nextIndex: number;
    switch (event.key) {
      case "ArrowDown":
        nextIndex = Math.min(selectedIndex + 1, records.length - 1);
        break;
      case "ArrowUp":
        nextIndex = selectedIndex < 0 ? records.length - 1 : Math.max(selectedIndex - 1, 0);
        break;
      case "Home":
        nextIndex = 0;
        break;
      case "End":
        nextIndex = records.length - 1;
        break;
      default:
        return;
    }

    event.preventDefault();
    const id = recordId(records[nextIndex]);
    if (id !== selectedRecordId) selectRecord(id);
    listRef.current?.children.item(nextIndex)?.scrollIntoView({ block: "nearest" });
  };
  const handleContextMenu = useCallback(
    (record: InspectorRecord, event: MouseEvent) => {
      event.preventDefault();
      event.stopPropagation();
      openContextMenu(record, event.clientX, event.clientY, false);
    },
    [openContextMenu]
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
      <div
        ref={listRef}
        className="record-list"
        role="listbox"
        aria-label="Network requests"
        aria-activedescendant={selectedIndex < 0 ? undefined : `${listId}-${selectedIndex}`}
        tabIndex={0}
        onKeyDown={handleKeyDown}
        onContextMenu={(event) => {
          if (event.target === event.currentTarget && openActiveContextMenu()) {
            event.preventDefault();
            event.stopPropagation();
          }
        }}
        onScroll={(event) => handleRecordListScroll(event, setShowTopFade)}
      >
        {records.map((record, index) => {
          const id = recordId(record);
          return (
            <RecordRow
              key={id}
              id={id}
              optionId={`${listId}-${index}`}
              record={record}
              selected={selectedRecordId === id}
              onSelect={selectRecord}
              onContextMenu={handleContextMenu}
            />
          );
        })}
      </div>
      <div className={showTopFade ? "record-list-top-fade visible" : "record-list-top-fade"} />
      {menu == null ? null : <ContextMenu menu={menu} autoFocus={menu.keyboard} onClose={closeContextMenu} />}
    </div>
  );
});

function handleRecordListScroll(event: UIEvent<HTMLDivElement>, setShowTopFade: (value: boolean) => void): void {
  setShowTopFade(event.currentTarget.scrollTop > 0);
}

const RecordRow = memo(function RecordRow({
  id,
  optionId,
  record,
  selected,
  onSelect,
  onContextMenu
}: {
  id: string;
  optionId: string;
  record: InspectorRecord;
  selected: boolean;
  onSelect(id: string): void;
  onContextMenu(record: InspectorRecord, event: MouseEvent): void;
}): JSX.Element {
  const path = splitUrl(record.url);
  return (
    <button
      id={optionId}
      type="button"
      role="option"
      aria-selected={selected}
      tabIndex={-1}
      className={`record-row ${selected ? "selected" : ""}`}
      onClick={() => onSelect(id)}
      onContextMenu={(event) => onContextMenu(record, event)}
    >
      <span className="record-main">
        <span className="record-primary">{path.primary}</span>
        <span className="record-secondary">{path.secondary}</span>
      </span>
      <span className="record-method">{record.method}</span>
      <StatusView record={record} />
    </button>
  );
});

export function sidebarContextMenuItems(
  clicked: InspectorRecord,
  selectedRecordId: string | null,
  allRecords: InspectorRecord[],
  client: NetworkClient,
  onAddExclusionFilter: (filter: string) => void,
  isConnected = true
): ContextMenuItem[] {
  const exportRecords = contextMenuExportSelection(clicked, selectedRecordId, allRecords);
  const exclusionFilter = exclusionFilterForUrl(clicked.url);
  const items: ContextMenuItem[] = [{ label: "Copy URL", action: () => void client.copyText(clicked.url) }];
  if (clicked.kind === "request") {
    items.push({ label: "Copy as cURL", action: () => void copyCurl(client, clicked, isConnected) });
  }
  items.push({
    label: "Add host to exclusion filter",
    action: () => {
      if (exclusionFilter != null) onAddExclusionFilter(exclusionFilter);
    },
    disabled: exclusionFilter == null
  });
  items.push({
    label: "Export HAR (sanitized)...",
    action: () => void exportAsHar(client, exportRecords, undefined, isConnected)
  });
  return items;
}
