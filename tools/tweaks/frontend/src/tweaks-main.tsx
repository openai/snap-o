import { render } from "preact";
import { TweaksApp } from "./TweaksApp";
import "../../../frontend/shared.css";
import "./features/tweaks-tool/tweaks.css";

render(<TweaksApp />, document.getElementById("root") as HTMLElement);
