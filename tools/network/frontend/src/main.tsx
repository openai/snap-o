import { render } from "preact";
import { host } from "@snap-o/tool-host";
import { App } from "./App";
import "./styles.css";

const root = document.getElementById("root") as HTMLElement;
render(<App />, root);
host.onError((error) =>
  render(
    <main className="empty-detail" role="alert">
      <h1>Could not connect to Snap-O</h1>
      <p>{error.message}</p>
      <button type="button" className="text-button" onClick={() => window.location.reload()}>
        Reload tool
      </button>
    </main>,
    root
  )
);
