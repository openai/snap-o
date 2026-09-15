import { render } from "preact";
import { host } from "@snap-o/tool-host";
import { TweaksApp } from "./TweaksApp";
import "../../../frontend/shared.css";
import "./features/tweaks-tool/tweaks.css";

const root = document.getElementById("root") as HTMLElement;
render(<TweaksApp />, root);
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
