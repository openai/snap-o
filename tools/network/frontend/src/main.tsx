import { render } from "preact";
import { host } from "@snap-o/tool-host";
import { App } from "./App";
import "./styles.css";

const root = document.getElementById("root") as HTMLElement;
render(<main className="empty-detail">Connecting to Snap-O…</main>, root);
void host.ready().then(
  () => render(<App />, root),
  (error: unknown) =>
    render(
      <main className="empty-detail" role="alert">
        <h1>Could not connect to Snap-O</h1>
        <p>{error instanceof Error ? error.message : "Snap-O did not return its connection details."}</p>
        <button type="button" className="text-button" onClick={() => window.location.reload()}>
          Reload tool
        </button>
      </main>,
      root
    )
);
