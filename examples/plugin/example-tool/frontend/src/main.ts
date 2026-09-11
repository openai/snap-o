import { host, type ColorPicker } from "@snap-o/plugin-host";
import { observeExample, type ExampleState } from "./snapshot";
import "./style.css";

const status = document.querySelector<HTMLParagraphElement>("#status")!;
const items = document.querySelector<HTMLTableSectionElement>("#items")!;
const feedback = document.querySelector<HTMLParagraphElement>("#feedback")!;
const copy = document.querySelector<HTMLButtonElement>("#copy")!;
const save = document.querySelector<HTMLButtonElement>("#save")!;
const color = document.querySelector<HTMLButtonElement>("#color")!;
const swatch = document.querySelector<HTMLSpanElement>("#swatch")!;
const increment = document.querySelector<HTMLButtonElement>("#increment")!;
let incrementing = false;
let filter = "";
let state: ExampleState = {
  connected: false,
  items: [],
  message: "Disconnected",
};
let picker: ColorPicker | undefined;
let disposed = false;

function render() {
  status.textContent = state.message;
  items.replaceChildren();
  for (const item of state.items.filter((item) =>
    `${item.name} ${item.value}`.toLowerCase().includes(filter),
  )) {
    const row = document.createElement("tr");
    for (const value of [item.name, String(item.value)]) {
      const cell = document.createElement("td");
      cell.textContent = value;
      row.append(cell);
    }
    items.append(row);
  }
  copy.disabled = save.disabled = state.items.length === 0;
  color.disabled = !state.connected;
  increment.disabled = incrementing || state.items.length === 0;
}

const observer = observeExample(host, (next) => {
  state = next;
  if (!state.connected) {
    picker?.close();
    picker = undefined;
    feedback.textContent = "";
  }
  render();
});

function report(error: unknown) {
  if (!disposed)
    feedback.textContent =
      error instanceof Error ? error.message : "Native helper failed.";
}

increment.addEventListener("click", () => {
  incrementing = true;
  render();
  void observer
    .increment()
    .catch(report)
    .finally(() => {
      incrementing = false;
      if (!disposed) render();
    });
});

void host
  .setToolbar({
    start: [
      {
        type: "button",
        id: "refresh",
        icon: "reset",
        label: "Refresh fake data",
        onClick: () => void observer.refresh(),
      },
      {
        type: "search",
        id: "search",
        label: "Search fake data",
        value: "",
        onChange(value) {
          filter = value.toLowerCase();
          render();
        },
      },
    ],
  })
  .catch(report);

copy.addEventListener("click", () => {
  void host
    .copyText(JSON.stringify(state.items, null, 2))
    .then(() => {
      feedback.textContent = "Copied fake data.";
    })
    .catch(report);
});
save.addEventListener("click", () => {
  void host
    .saveFile({
      name: "example-fake-data.json",
      data: new Blob([JSON.stringify(state.items, null, 2)], {
        type: "application/json",
      }),
    })
    .then((saved) => {
      feedback.textContent = saved ? "Saved fake data." : "Save cancelled.";
    })
    .catch(report);
});
color.addEventListener("click", () => {
  picker?.close();
  void host
    .openColorPicker({
      value: "#6688ccff",
      onChange(value) {
        swatch.style.backgroundColor = value;
      },
      onClose() {
        picker = undefined;
      },
    })
    .then((opened) => {
      if (disposed || !host.connected) opened.close();
      else picker = opened;
    })
    .catch(report);
});

window.addEventListener(
  "pagehide",
  () => {
    disposed = true;
    observer.dispose();
    picker?.close();
    void host.setToolbar({ start: [] }).catch(() => {});
  },
  { once: true },
);
