import { render } from "preact";
import { TweaksApp } from "./TweaksApp";
import "./shared.css";
import "./features/tweaks-inspector/tweaks.css";

render(<TweaksApp />, document.getElementById("root") as HTMLElement);
