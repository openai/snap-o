import { NetworkInspectorApp } from "./features/network-inspector/NetworkInspectorApp";

export function App(): JSX.Element {
  return (
    <div className="window-frame">
      <header className="window-titlebar" aria-hidden="true">
        <div className="window-titlebar-title">Snap-O Network Inspector</div>
      </header>
      <NetworkInspectorApp />
    </div>
  );
}
