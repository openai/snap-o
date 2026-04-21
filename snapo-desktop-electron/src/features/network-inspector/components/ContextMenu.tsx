export interface ContextMenuState {
  x: number;
  y: number;
  items: ContextMenuItem[];
}

export interface ContextMenuItem {
  label: string;
  action: () => void;
}

export function ContextMenu({ menu, onClose }: { menu: ContextMenuState; onClose: () => void }): JSX.Element {
  return (
    <div className="context-menu" style={{ left: menu.x, top: menu.y }} onPointerDown={(event) => event.stopPropagation()}>
      {menu.items.map((item) => (
        <button
          className="context-menu-item"
          type="button"
          key={item.label}
          onClick={() => {
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
