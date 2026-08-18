import { useLayoutEffect, useRef, type KeyboardEvent } from "react";

export interface ContextMenuState {
  x: number;
  y: number;
  items: ContextMenuItem[];
}

export interface ContextMenuItem {
  label: string;
  action: () => void;
  disabled?: boolean;
}

export function contextMenuPosition({
  x,
  y,
  width,
  height,
  viewportWidth,
  viewportHeight,
  inset = 4
}: {
  x: number;
  y: number;
  width: number;
  height: number;
  viewportWidth: number;
  viewportHeight: number;
  inset?: number;
}): { left: number; top: number } {
  return {
    left: Math.max(inset, Math.min(x, viewportWidth - width - inset)),
    top: Math.max(inset, Math.min(y, viewportHeight - height - inset))
  };
}

export function ContextMenu({
  menu,
  autoFocus = false,
  onClose
}: {
  menu: ContextMenuState;
  autoFocus?: boolean;
  onClose: () => void;
}): JSX.Element {
  const menuRef = useRef<HTMLDivElement>(null);

  useLayoutEffect(() => {
    if (autoFocus) menuRef.current?.querySelector<HTMLButtonElement>("button:not(:disabled)")?.focus();
  }, [autoFocus, menu]);

  const handleKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    // Callers dismiss menus on window keydown. Let the menu finish handling its own keys first.
    event.stopPropagation();
    if (event.defaultPrevented || event.nativeEvent.isComposing || event.altKey || event.ctrlKey || event.metaKey)
      return;

    if (event.key === "Escape" || event.key === "Tab") {
      if (event.key === "Escape") event.preventDefault();
      onClose();
      return;
    }

    const items = [...event.currentTarget.querySelectorAll<HTMLButtonElement>("button:not(:disabled)")];
    const current = items.findIndex((item) => item === document.activeElement);
    let next: number;
    switch (event.key) {
      case "ArrowDown":
        next = (current + 1) % items.length;
        break;
      case "ArrowUp":
        next = current < 0 ? items.length - 1 : (current + items.length - 1) % items.length;
        break;
      case "Home":
        next = 0;
        break;
      case "End":
        next = items.length - 1;
        break;
      case "Enter":
      case " ":
        event.preventDefault();
        items[current]?.click();
        return;
      default:
        return;
    }
    event.preventDefault();
    items[next]?.focus();
  };

  useLayoutEffect(() => {
    const element = menuRef.current;
    if (element == null) return;

    const positionMenu = () => {
      const { width, height } = element.getBoundingClientRect();
      const { left, top } = contextMenuPosition({
        x: menu.x,
        y: menu.y,
        width,
        height,
        viewportWidth: window.innerWidth,
        viewportHeight: window.innerHeight
      });
      element.style.left = `${left}px`;
      element.style.top = `${top}px`;
    };

    positionMenu();
    window.addEventListener("resize", positionMenu);
    return () => window.removeEventListener("resize", positionMenu);
  }, [menu]);

  return (
    <div
      ref={menuRef}
      className="context-menu"
      role="menu"
      style={{ left: menu.x, top: menu.y }}
      onPointerDown={(event) => event.stopPropagation()}
      onKeyDown={handleKeyDown}
    >
      {menu.items.map((item) => (
        <button
          className="context-menu-item"
          type="button"
          role="menuitem"
          tabIndex={autoFocus ? -1 : undefined}
          disabled={item.disabled}
          key={item.label}
          onClick={() => {
            if (item.disabled === true) return;
            item.action();
            onClose();
          }}
        >
          {item.label}
        </button>
      ))}
    </div>
  );
}
