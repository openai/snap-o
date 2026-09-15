import { render } from "preact";
import { useEffect, useState } from "preact/hooks";
import { host } from "@snap-o/tool-host";

function App() {
  const [message, setMessage] = useState("Disconnected");

  useEffect(() => host.onError(error => {
    setMessage(`Could not connect to Snap-O: ${error.message}`);
  }), []);

  useEffect(() => host.onConnection(async connection => {
    setMessage(connection ? "Connecting…" : "Disconnected");
    if (!connection) return;
    try {
      const response = await fetch("/api/example");
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      setMessage(data.message);
    } catch (error) {
      setMessage(`Request failed: ${String(error)}`);
    }
  }), []);

  return <output>{message}</output>;
}

render(<App />, document.getElementById("app")!);
