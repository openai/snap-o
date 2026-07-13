import { useLayoutEffect, useRef } from "react";

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

export function ContextMenu({ menu, onClose }: { menu: ContextMenuState; onClose: () => void }): JSX.Element {
  const menuRef = useRef<HTMLDivElement>(null);

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
      style={{ left: menu.x, top: menu.y }}
      onPointerDown={(event) => event.stopPropagation()}
    >
      {menu.items.map((item) => (
        <button
          className="context-menu-item"
          type="button"
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
