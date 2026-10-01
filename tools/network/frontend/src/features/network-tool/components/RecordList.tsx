import type { JSX } from "preact";
import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from "preact/hooks";
import type { NetworkClient } from "../../../network/client";
import { recordId, type ToolRecord } from "../../../network/cdp";
import { ContextMenu, type ContextMenuItem, type ContextMenuState } from "./ContextMenu";
import { StatusView } from "./Status";
import { copyCurl, exportAsHar } from "../lib/exportActions";
import { exclusionFilterForUrl } from "../lib/exclusionFilters";
import { contextMenuExportSelection, splitUrl } from "../lib/records";

type ScrollAnchor = { row: Element; offset: number };

export function RecordList({
  records,
  allRecords,
  sortNewestFirst,
  placeholder,
  selectedRecordId,
  onSelect,
  onAddExclusionFilter,
  client,
  isConnected = true
}: {
  records: ToolRecord[];
  allRecords: ToolRecord[];
  sortNewestFirst: boolean;
  placeholder: string | null;
  selectedRecordId: string | null;
  onSelect(id: string): void;
  onAddExclusionFilter(value: string): void;
  client: NetworkClient;
  isConnected?: boolean;
}): JSX.Element {
  const listId = useId();
  const listRef = useRef<HTMLDivElement>(null);
  const followNewestRef = useRef(true);
  const scrollAnchorRef = useRef<ScrollAnchor | null>(null);
  const selectedIndex = records.findIndex((record) => recordId(record) === selectedRecordId);
  const [menu, setMenu] = useState<(ContextMenuState & { keyboard: boolean }) | null>(null);
  const [showTopFade, setShowTopFade] = useState(false);
  const updateScrollState = useCallback(() => {
    const list = listRef.current;
    if (list == null || list.clientHeight === 0) return;
    // Allow for fractional scroll positions at either edge.
    const distance = sortNewestFirst ? list.scrollTop : list.scrollHeight - list.clientHeight - list.scrollTop;
    followNewestRef.current = distance <= 1;
    scrollAnchorRef.current = followNewestRef.current ? null : getScrollAnchor(list);
    setShowTopFade(list.scrollTop > 0);
  }, [sortNewestFirst]);

  const restoreScrollPosition = useCallback(() => {
    const list = listRef.current;
    if (list == null) {
      followNewestRef.current = true;
      scrollAnchorRef.current = null;
      setShowTopFade(false);
      return;
    }
    if (list.clientHeight === 0) return;
    const anchor = scrollAnchorRef.current;
    if (followNewestRef.current) {
      list.scrollTop = sortNewestFirst ? 0 : list.scrollHeight;
    } else if (anchor != null && list.contains(anchor.row)) {
      // Keep the same request in view when rows are prepended or reordered.
      list.scrollTop += anchor.row.getBoundingClientRect().top - list.getBoundingClientRect().top - anchor.offset;
    }
    updateScrollState();
  }, [sortNewestFirst, updateScrollState]);

  useLayoutEffect(restoreScrollPosition, [records, placeholder, restoreScrollPosition]);

  useLayoutEffect(() => {
    const list = listRef.current;
    if (list == null) return;
    // Resizing can reach the newest edge without firing a scroll event.
    const observer = new ResizeObserver(restoreScrollPosition);
    observer.observe(list);
    return () => observer.disconnect();
  }, [placeholder, restoreScrollPosition]);

  const selectRecord = useCallback(
    (id: string) => {
      // WebKit does not always focus buttons on click. Keep keyboard ownership on the list.
      listRef.current?.focus({ preventScroll: true });
      onSelect(id);
    },
    [onSelect]
  );
  const openContextMenu = useCallback(
    (record: ToolRecord, x: number, y: number, keyboard: boolean) => {
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
    updateScrollState();
    const { left, bottom } = row.getBoundingClientRect();
    openContextMenu(record, left, bottom, true);
    return true;
  };
  const closeContextMenu = () => {
    setMenu(null);
    listRef.current?.focus({ preventScroll: true });
  };
  const handleKeyDown = (event: JSX.TargetedKeyboardEvent<HTMLDivElement>) => {
    if (event.defaultPrevented || event.isComposing || event.altKey || event.ctrlKey || event.metaKey) return;
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
    const list = listRef.current;
    if (list != null && nextIndex === (sortNewestFirst ? 0 : records.length - 1)) {
      // Include trailing padding so reaching the newest row resumes following.
      list.scrollTop = sortNewestFirst ? 0 : list.scrollHeight;
    } else {
      list?.children.item(nextIndex)?.scrollIntoView({ block: "nearest" });
    }
    updateScrollState();
  };
  const handleContextMenu = useCallback(
    (record: ToolRecord, event: JSX.TargetedMouseEvent<HTMLButtonElement>) => {
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
        onScroll={updateScrollState}
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
}

function getScrollAnchor(list: HTMLElement): ScrollAnchor | null {
  const top = list.getBoundingClientRect().top;
  let start = 0;
  let end = list.children.length;
  // Find the first visible row without measuring every request on each scroll.
  while (start < end) {
    const middle = Math.floor((start + end) / 2);
    if (list.children[middle].getBoundingClientRect().bottom <= top) start = middle + 1;
    else end = middle;
  }
  const row = list.children.item(start);
  return row == null ? null : { row, offset: row.getBoundingClientRect().top - top };
}

function RecordRow({
  id,
  optionId,
  record,
  selected,
  onSelect,
  onContextMenu
}: {
  id: string;
  optionId: string;
  record: ToolRecord;
  selected: boolean;
  onSelect(id: string): void;
  onContextMenu(record: ToolRecord, event: JSX.TargetedMouseEvent<HTMLButtonElement>): void;
}): JSX.Element {
  return useMemo(() => {
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
  }, [id, optionId, record, selected, onSelect, onContextMenu]);
}

export function sidebarContextMenuItems(
  clicked: ToolRecord,
  selectedRecordId: string | null,
  allRecords: ToolRecord[],
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
    label: `Add ${exclusionFilter?.slice(1) ?? "host"} to exclusion filter`,
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
