import { NetworkInspectorApp } from "./features/network-inspector/NetworkInspectorApp";

export function App(): JSX.Element {
  return (
    <div className="window-frame">
      <NetworkInspectorApp />
    </div>
  );
}
