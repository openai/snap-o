const state = {
  apps: [],
  selectedAppId: undefined,
  selectedView: "tweaks",
  tweaks: [],
  rows: new Map(),
  orderingByApp: new Map(),
  pending: new Map(),
  inFlight: new Set(),
  eventSource: undefined,
  timer: undefined,
  pollTimer: undefined,
  refreshing: false,
  saving: false,
  switching: false,
  menuOpen: false,
};

const isMockMode = typeof window !== "undefined" &&
  new URLSearchParams(window.location.search).has("mock");

const isAppGroupedMock = isMockMode &&
  new URLSearchParams(window.location.search).get("mock") === "apps";

const mockApps = [
  {
    id: "mock:notes",
    name: "Notes Demo",
    packageName: "com.example.notes",
    deviceName: "Pixel 9 Pro XL",
    views: ["network", "tweaks"],
  },
  {
    id: "mock:tweaks-demo",
    name: "Snap-O Tweaks Demo",
    packageName: "com.openai.snapo.demo.tweaks",
    deviceName: "Pixel 9 Pro XL",
    views: ["tweaks"],
  },
  {
    id: "mock:emulator:notes",
    name: "Notes Demo",
    packageName: "com.example.notes",
    deviceName: "Android Emulator",
    views: ["network"],
  },
];

const mockTweaks = [
  { name: "Colors/Text", type: "color", default: "#18212F", value: "#18212F" },
  { name: "Colors/Background", type: "color", default: "#F7F8FA", value: "#F7F8FA" },
  { name: "Colors/Accent", type: "color", default: "#5468FF", value: "#5468FF" },
  { name: "Typography/Font size", type: "int", default: 36, value: 36, min: 16, max: 72, step: 1 },
  { name: "Typography/Font weight", type: "int", default: 600, value: 600, min: 100, max: 900, step: 100 },
  { name: "Typography/Preview text", type: "string", default: "Make it feel right.", value: "Make it feel right." },
  { name: "Motion/Show", type: "boolean", default: true, value: true },
  { name: "Motion/Duration", type: "int", default: 400, value: 400, min: 100, max: 1500, step: 50 },
  { name: "Motion/Spring stiffness", type: "float", default: 280, value: 280, min: 80, max: 800, step: 20 },
  { name: "Motion/Spring damping", type: "float", default: 0.7, value: 0.7, min: 0.1, max: 1, step: 0.05 },
  { name: "Motion/Use spring", type: "boolean", default: true, value: true },
  {
    name: "Motion/Marker shape",
    type: "enum",
    default: "Circle",
    value: "Circle",
    options: ["Circle", "RoundedSquare", "Square"],
  },
];

let mockSelectedAppId = mockApps[0].id;

const elements = {
  appPicker: document.querySelector("#app-picker"),
  appChevron: document.querySelector("#app-chevron"),
  appList: document.querySelector("#app-list"),
  inspectorSegments: document.querySelector("#inspector-segments"),
  appIcon: document.querySelector(".app-icon"),
  appName: document.querySelector("#app-name"),
  packageName: document.querySelector("#package-name"),
  deviceName: document.querySelector("#device-name"),
  status: document.querySelector("#connection-status"),
  statusText: document.querySelector("#status-text"),
  error: document.querySelector("#error-message"),
  empty: document.querySelector("#empty-state"),
  sections: document.querySelector("#tweak-sections"),
  reset: document.querySelector("#reset-button"),
};

function node(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}

function setStatus(value, label = value) {
  elements.status.dataset.state = value;
  elements.status.setAttribute("aria-label", label);
  elements.status.setAttribute("title", label);
  elements.statusText.textContent = label;
}

function setError(message) {
  elements.error.hidden = !message;
  elements.error.textContent = message ?? "";
}

function updateError(result) {
  if (!result.errors?.length) return undefined;
  return result.errors.map(({ name, error }) => `${name}: ${error}`).join("; ");
}

async function request(path, options) {
  if (isMockMode) return mockRequest(path, options);

  const response = await fetch(path, {
    cache: "no-store",
    ...options,
  });
  const payload = await response.json();

  if (!response.ok) {
    throw new Error(payload.error ?? `Request failed (${response.status}).`);
  }

  return payload;
}

function mockRequest(path, options) {
  if (path === "/apps") {
    return { apps: structuredClone(mockApps), selectedAppId: mockSelectedAppId };
  }

  if (path === "/apps/selection") {
    const { id } = JSON.parse(options.body);
    const app = mockApps.find((candidate) => candidate.id === id);

    if (!app) throw new Error("The selected app is not available.");

    mockSelectedAppId = id;
    return { app: structuredClone(app) };
  }

  if (path === "/app") {
    return structuredClone(mockApps.find((app) => app.id === mockSelectedAppId));
  }

  if (path === "/tweaks" && options?.method === "PATCH") {
    const { values } = JSON.parse(options.body);

    for (const tweak of mockTweaks) {
      if (Object.hasOwn(values, tweak.name)) tweak.value = values[tweak.name];
    }

    return {
      tweaks: Object.entries(values).map(([name, value]) => ({ name, value })),
    };
  }

  if (path === "/tweaks") {
    const showMotion = mockTweaks.find((tweak) => tweak.name === "Motion/Show");
    const tweaks = mockTweaks.filter((tweak) =>
      showMotion.value || !tweak.name.startsWith("Motion/") || tweak.name === "Motion/Show"
    );

    return { tweaks: structuredClone(tweaks) };
  }

  throw new Error("The mock route is not available.");
}

function updateResetButton() {
  elements.reset.disabled =
    state.saving ||
    state.switching ||
    state.tweaks.length === 0 ||
    state.tweaks.every((tweak) => tweak.value === tweak.default);
}

function setAppMenuOpen(open) {
  const hasChoices = state.apps.length > 1 ||
    state.apps.some((app) => (app.views?.length ?? 0) > 1);
  state.menuOpen = open && hasChoices && !state.switching;
  elements.appList.hidden = !state.menuOpen;
  elements.appPicker.setAttribute("aria-expanded", String(state.menuOpen));
}

function renderApps() {
  const multipleApps = state.apps.length > 1 ||
    state.apps.some((app) => (app.views?.length ?? 0) > 1);
  elements.appPicker.disabled = state.switching || !multipleApps;
  elements.appPicker.dataset.available = String(state.apps.length > 0);
  elements.appPicker.dataset.multiple = String(multipleApps);
  elements.appChevron.hidden = !multipleApps;
  renderInspectorViews();

  if (isMockMode) {
    renderMockApps();
    return;
  }

  renderAppGroupedMenu();
}

function renderInspectorViews() {
  const app = state.apps.find((candidate) => candidate.id === state.selectedAppId);
  const views = app?.views ?? (app ? ["tweaks"] : []);

  elements.inspectorSegments.hidden = views.length < 2;

  if (!app || views.length < 2) {
    elements.inspectorSegments.replaceChildren();
    return;
  }

  const segments = views.map((view) => {
    const title = view === "network" ? "Network" : "Tweaks";
    const selected = view === state.selectedView;
    const button = node("button", "inspector-segment");

    button.type = "button";
    button.disabled = state.switching;
    button.setAttribute("aria-label", `${title} inspector`);
    button.setAttribute("aria-pressed", String(selected));
    button.setAttribute("title", title);
    button.append(mockIcon(view === "network" ? "network" : "tweaks", "inspector-segment-icon"));
    button.addEventListener("click", () => {
      if (state.switching || view === state.selectedView) return;

      state.selectedView = view;
      updateAppIdentity(app);
      renderApps();
      setAppMenuOpen(false);
    });
    return button;
  });

  elements.inspectorSegments.replaceChildren(...segments);
}

function mockIcon(name, className = "mock-menu-icon") {
  const namespace = "http://www.w3.org/2000/svg";
  const icon = document.createElementNS(namespace, "svg");
  const use = document.createElementNS(namespace, "use");

  icon.setAttribute("class", className);
  icon.setAttribute("viewBox", "0 0 24 24");
  icon.setAttribute("aria-hidden", "true");
  use.setAttribute("href", `#mock-icon-${name}`);
  icon.append(use);
  return icon;
}

function renderMockApps() {
  if (isAppGroupedMock) {
    renderAppGroupedMenu();
    return;
  }

  const rows = [];

  for (const view of ["network", "tweaks"]) {
    const apps = state.apps.filter((app) => (app.views ?? ["tweaks"]).includes(view));

    if (apps.length === 0) continue;

    const viewName = view === "network" ? "Network" : "Tweaks";
    const heading = node("div", "mock-menu-heading");

    heading.setAttribute("role", "presentation");
    heading.append(
      mockIcon(view === "network" ? "network" : "tweaks", "mock-heading-icon"),
      node("span", undefined, viewName),
    );
    rows.push(heading);

    for (const app of apps) {
      const selected = app.id === state.selectedAppId && view === state.selectedView;
      const button = node("button", "mock-menu-choice");
      const identity = node("span", "mock-choice-identity");

      button.type = "button";
      button.dataset.selected = String(selected);
      button.setAttribute("role", "menuitemradio");
      button.setAttribute("aria-checked", String(selected));
      button.setAttribute("aria-label", `${app.name}, ${viewName}, ${app.deviceName}`);
      button.setAttribute("title", app.packageName);

      identity.append(
        node("span", "mock-choice-name", app.name),
        node("span", "mock-choice-device", app.deviceName),
      );
      button.append(
        mockIcon("app", "mock-choice-app-icon"),
        identity,
        mockIcon("check", "mock-menu-check"),
      );

      button.addEventListener("click", async () => {
        state.selectedView = view;

        if (app.id !== state.selectedAppId) await selectApp(app.id);

        elements.appName.textContent = app.name;
        renderApps();
        setAppMenuOpen(false);
      });
      rows.push(button);
    }
  }

  elements.appList.replaceChildren(...rows);
  setAppMenuOpen(state.menuOpen);
}

function appMenuIcon(app) {
  if (isMockMode) return mockIcon("app", "mock-app-heading-icon");

  const icon = node("img", "mock-app-heading-icon");
  icon.src = `/apps/${encodeURIComponent(app.id)}/icon`;
  icon.alt = "";
  icon.width = 15;
  icon.height = 15;
  icon.addEventListener("error", () => {
    icon.hidden = true;
  });
  return icon;
}

function renderAppGroupedMenu() {
  const rows = [];

  for (const app of state.apps) {
    if (rows.length > 0) rows.push(node("div", "mock-app-separator"));

    const heading = node("div", "mock-app-heading");

    heading.setAttribute("role", "presentation");
    heading.setAttribute("title", app.packageName);
    heading.append(
      appMenuIcon(app),
      node("span", "mock-app-heading-name", app.name),
      node("span", "mock-app-heading-device", app.deviceName),
    );
    rows.push(heading);

    for (const view of app.views ?? ["tweaks"]) {
      const viewName = view === "network" ? "Network" : "Tweaks";
      const selected = app.id === state.selectedAppId && view === state.selectedView;
      const button = node("button", "mock-menu-choice mock-app-view-choice");

      button.type = "button";
      button.dataset.selected = String(selected);
      button.disabled = state.switching;
      button.setAttribute("role", "menuitemradio");
      button.setAttribute("aria-checked", String(selected));
      button.setAttribute("aria-pressed", String(selected));
      button.setAttribute("aria-label", `${app.name}, ${viewName}, ${app.deviceName}`);
      button.setAttribute("title", app.packageName);
      button.append(
        mockIcon(view === "network" ? "network" : "tweaks", "mock-app-view-icon"),
        node("span", "mock-app-view-name", viewName),
        mockIcon("check", "mock-menu-check"),
      );

      button.addEventListener("click", async () => {
        state.selectedView = view;

        if (app.id !== state.selectedAppId) await selectApp(app.id);

        if (isMockMode) elements.appName.textContent = app.name;
        renderApps();
        setAppMenuOpen(false);
      });
      rows.push(button);
    }
  }

  elements.appList.replaceChildren(...rows);
  setAppMenuOpen(state.menuOpen);
}

function showEmptyState() {
  closeTweakStream();
  state.tweaks = [];
  state.rows.clear();
  elements.appName.textContent = "No app selected";
  elements.packageName.textContent = "";
  elements.deviceName.textContent = "";
  elements.appIcon.hidden = true;
  elements.appPicker.removeAttribute?.("title");
  elements.empty.hidden = false;
  document.title = "Tweaks · Snap-O";
  renderTweaks();
  setError();
  setStatus("disconnected", "No apps found");
}

function updateAppIdentity(app) {
  elements.appName.textContent = app.name;
  elements.packageName.textContent = app.packageName;
  elements.deviceName.textContent = app.deviceName;
  if (isMockMode) {
    elements.appIcon.hidden = true;

    const frame = elements.appIcon.parentElement;

    if (frame && !frame.querySelector(".mock-toolbar-icon")) {
      frame.prepend(mockIcon("app", "mock-toolbar-icon"));
    }
  } else {
    elements.appIcon.src = `/apps/${encodeURIComponent(app.id)}/icon`;
    elements.appIcon.hidden = false;
  }
  elements.appPicker.setAttribute("title", app.packageName);
  elements.empty.hidden = true;
  document.title = `${app.name} · Snap-O Tweaks`;
}

function updateTweakRow(tweak) {
  const fields = state.rows.get(tweak.name);
  if (!fields) return;

  const changed = tweak.value !== tweak.default;
  fields.row.dataset.changed = String(changed);
  fields.reset.hidden = !changed;

  if (fields.number) fields.number.value = numberText(tweak.value);
  if (fields.slider) fields.slider.value = numberText(tweak.value);
  if (fields.color) fields.color.value = tweak.value.slice(0, 7);
  if (fields.hex) fields.hex.value = tweak.value;
  if (fields.text) fields.text.value = tweak.value;
  if (fields.checkbox) fields.checkbox.checked = tweak.value;
  if (fields.selection) fields.selection.value = tweak.value;
}

function updateValue(tweak, value, delay = 75) {
  if (state.switching) return;
  tweak.value = value;
  state.pending.set(tweak.name, value);
  updateTweakRow(tweak);
  updateResetButton();
  clearTimeout(state.timer);
  state.timer = undefined;

  if (state.saving) return;

  if (delay === 0) {
    void flushPending();
    return;
  }

  state.timer = setTimeout(flushPending, delay);
}

async function flushPending() {
  if (state.saving || state.pending.size === 0) return;

  const values = Object.fromEntries(state.pending);
  state.pending.clear();
  for (const name of Object.keys(values)) state.inFlight.add(name);
  state.saving = true;
  setStatus("connected", "Saving…");
  updateResetButton();

  try {
    const result = await request("/tweaks", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ values }),
    });

    for (const update of result.tweaks) {
      const tweak = state.tweaks.find((item) => item.name === update.name);
      if (tweak && !state.pending.has(update.name)) {
        tweak.value = update.value;
        updateTweakRow(tweak);
      }
    }

    const error = updateError(result);
    if (error) {
      await reloadTweaks();
      setError(error);
      setStatus("error", "Some updates failed");
    } else {
      setError();
      setStatus("connected", "Connected");
    }
  } catch (error) {
    setError(error.message);
    setStatus("error", "Update failed");
    await reloadTweaks();
  } finally {
    for (const name of Object.keys(values)) state.inFlight.delete(name);
    state.saving = false;
    updateResetButton();

    if (state.pending.size > 0) {
      clearTimeout(state.timer);
      state.timer = undefined;
      void flushPending();
    }
  }
}

function makeTweakLine(tweak) {
  const line = node("div", "tweak-line");
  const content = node("div", "tweak-content");
  const actions = node("div", "tweak-actions");
  const reset = node("button", "tweak-reset");
  reset.type = "button";
  reset.hidden = tweak.value === tweak.default;
  reset.setAttribute("aria-label", `Reset ${tweak.name}`);
  reset.setAttribute("title", `Reset ${tweakLabel(tweak.name)}`);
  reset.append(mockIcon("rotate-ccw", "tweak-reset-icon"));
  reset.addEventListener("click", () => {
    updateValue(tweak, tweak.default, 0);
  });

  content.append(node("span", "tweak-label", tweakLabel(tweak.name)), reset, actions);
  line.append(content);
  return { line, actions, reset };
}

function registerTweakRow(tweak, row, fields) {
  state.rows.set(tweak.name, { row, ...fields });
  updateTweakRow(tweak);
  return row;
}

function numberText(value) {
  return Number.parseFloat(Number(value).toFixed(6)).toString();
}

function makeNumberTweak(tweak) {
  const row = node("div", "tweak-row");
  const { line, actions, reset } = makeTweakLine(tweak);
  const input = node("input", "number-input");
  input.type = "number";
  input.value = numberText(tweak.value);
  input.setAttribute("aria-label", `${tweak.name} value`);

  if (tweak.min !== undefined) input.min = numberText(tweak.min);
  if (tweak.max !== undefined) input.max = numberText(tweak.max);
  input.step = numberText(tweak.step ?? (tweak.type === "int" ? 1 : 0.01));

  actions.append(input);
  row.append(line);

  let slider;
  if (tweak.min !== undefined && tweak.max !== undefined) {
    slider = node("input", "range-input");
    slider.type = "range";
    slider.min = numberText(tweak.min);
    slider.max = numberText(tweak.max);
    slider.step = input.step;
    slider.value = numberText(tweak.value);
    slider.setAttribute("aria-label", tweak.name);

    slider.addEventListener("input", () => {
      const value = Number(slider.value);
      input.value = numberText(value);
      input.setAttribute("aria-invalid", "false");
      updateValue(tweak, value, 0);
    });

    row.append(slider);
  }

  input.addEventListener("input", () => {
    const value = Number(input.value);
    const valid =
      input.value !== "" &&
      input.validity.valid &&
      Number.isFinite(value) &&
      (tweak.type !== "int" || Number.isInteger(value));

    input.setAttribute("aria-invalid", String(!valid));
    if (!valid) return;

    if (slider) slider.value = numberText(value);
    updateValue(tweak, value);
  });

  return registerTweakRow(tweak, row, {
    reset,
    number: input,
    slider,
  });
}

function makeColorTweak(tweak) {
  const row = node("div", "tweak-row");
  const { line, actions, reset } = makeTweakLine(tweak);
  const inputs = node("div", "color-inputs");

  const picker = node("input", "color-input");
  picker.type = "color";
  picker.value = tweak.value.slice(0, 7);
  picker.setAttribute("aria-label", `${tweak.name} color`);

  const hex = node("input", "hex-input");
  hex.type = "text";
  hex.value = tweak.value;
  hex.spellcheck = false;
  hex.maxLength = 9;
  hex.setAttribute("aria-label", `${tweak.name} hex`);

  picker.addEventListener("input", () => {
    const alpha = tweak.value.length === 9 ? tweak.value.slice(7) : "";
    const value = `${picker.value.toUpperCase()}${alpha.toUpperCase()}`;
    hex.value = value;
    hex.setAttribute("aria-invalid", "false");
    updateValue(tweak, value, 0);
  });

  hex.addEventListener("input", () => {
    const valid = /^#[\da-f]{6}(?:[\da-f]{2})?$/i.test(hex.value);
    hex.setAttribute("aria-invalid", String(!valid));
    if (!valid) return;

    const value = hex.value.toUpperCase();
    picker.value = value.slice(0, 7);
    updateValue(tweak, value);
  });

  inputs.append(picker, hex);
  actions.append(inputs);
  row.append(line);
  return registerTweakRow(tweak, row, {
    reset,
    color: picker,
    hex,
  });
}

function makeBooleanTweak(tweak) {
  const row = node("div", "tweak-row");
  const { line, actions, reset } = makeTweakLine(tweak);
  const input = node("input", "boolean-input");
  input.type = "checkbox";
  input.checked = tweak.value;
  input.setAttribute("aria-label", tweak.name);
  input.addEventListener("change", () => {
    updateValue(tweak, input.checked, 0);
  });

  actions.append(input);
  row.append(line);
  return registerTweakRow(tweak, row, {
    reset,
    checkbox: input,
  });
}

function makeStringTweak(tweak) {
  const row = node("div", "tweak-row");
  const { line, reset } = makeTweakLine(tweak);
  const input = node("input", "string-input");
  input.type = "text";
  input.value = tweak.value;
  input.setAttribute("aria-label", tweak.name);
  input.addEventListener("input", () => {
    updateValue(tweak, input.value, 130);
  });

  row.append(line, input);
  return registerTweakRow(tweak, row, {
    reset,
    text: input,
  });
}

function makeEnumTweak(tweak) {
  const row = node("div", "tweak-row");
  const { line, actions, reset } = makeTweakLine(tweak);
  const input = node("select", "enum-input");

  input.setAttribute("aria-label", tweak.name);
  input.replaceChildren(...tweak.options.map((value) => {
    const option = node("option", undefined, value);
    option.value = value;
    return option;
  }));
  input.value = tweak.value;
  input.addEventListener("change", () => {
    updateValue(tweak, input.value, 0);
  });

  actions.append(input);
  row.append(line);
  return registerTweakRow(tweak, row, {
    reset,
    selection: input,
  });
}

function makeTweak(tweak) {
  switch (tweak.type) {
    case "int":
    case "float":
      return makeNumberTweak(tweak);
    case "color":
      return makeColorTweak(tweak);
    case "boolean":
      return makeBooleanTweak(tweak);
    case "string":
      return makeStringTweak(tweak);
    case "enum":
      return makeEnumTweak(tweak);
    default:
      return null;
  }
}

function tweakPath(name) {
  const separator = name.indexOf("/");

  if (separator <= 0 || separator === name.length - 1) {
    return { section: undefined, label: name };
  }

  const section = name.slice(0, separator).trim();
  const label = name.slice(separator + 1).trim();

  return section && label
    ? { section, label }
    : { section: undefined, label: name };
}

function tweakLabel(name) {
  return tweakPath(name).label;
}

function tweakOrdering() {
  const appId = state.selectedAppId ?? "";
  let ordering = state.orderingByApp.get(appId);

  if (!ordering) {
    ordering = { sections: new Map(), tweaks: new Map() };
    state.orderingByApp.set(appId, ordering);
  }

  return ordering;
}

function renderTweaks() {
  state.rows.clear();

  const ordering = tweakOrdering();
  const activeSections = new Map();

  for (const tweak of state.tweaks) {
    const { section } = tweakPath(tweak.name);
    const sectionKey = section ?? "";

    if (!ordering.sections.has(sectionKey)) {
      ordering.sections.set(sectionKey, ordering.sections.size);
    }

    if (!ordering.tweaks.has(tweak.name)) {
      ordering.tweaks.set(tweak.name, ordering.tweaks.size);
    }

    if (!activeSections.has(sectionKey)) activeSections.set(sectionKey, []);
    activeSections.get(sectionKey).push(tweak);
  }

  const sections = [...activeSections.entries()]
    .sort(([left], [right]) =>
      ordering.sections.get(left) - ordering.sections.get(right),
    )
    .map(([name, tweaks]) => {
      const section = node("section", "tweak-section");
      section.dataset.section = name;
      section.dataset.order = String(ordering.sections.get(name));

      if (name) {
        const heading = node("div", "section-heading");
        heading.append(node("h2", undefined, name));
        section.append(heading);
      }

      const list = node("div", "tweak-list");
      list.replaceChildren(
        ...tweaks
          .sort((left, right) =>
            ordering.tweaks.get(left.name) - ordering.tweaks.get(right.name),
          )
          .map(makeTweak)
          .filter((tweak) => tweak !== null),
      );
      section.append(list);
      return section;
    });

  const columnCount = Math.min(2, ordering.sections.size);
  const columns = Array.from({ length: columnCount }, (_, index) => {
    const column = node("div", "tweak-column");
    column.dataset.column = String(index);
    return column;
  });

  for (const section of sections) {
    const index = ordering.sections.get(section.dataset.section) % columnCount;
    columns[index].append(section);
  }

  elements.sections.replaceChildren(...columns);
  updateResetButton();
}

async function reloadTweaks() {
  const result = await request("/tweaks");
  state.tweaks = result.tweaks;
  renderTweaks();
}

function sameTweakShape(current, incoming) {
  if (current.length !== incoming.length) return false;

  return current.every((tweak, index) => {
    const next = incoming[index];

    return (
      tweak.name === next.name &&
      tweak.type === next.type &&
      tweak.default === next.default &&
      tweak.min === next.min &&
      tweak.max === next.max &&
      tweak.step === next.step &&
      sameTweakOptions(tweak.options, next.options)
    );
  });
}

function sameTweakOptions(current, incoming) {
  if (current === undefined || incoming === undefined) {
    return current === incoming;
  }

  return current.length === incoming.length &&
    current.every((option, index) => option === incoming[index]);
}

function applyTweakSnapshot(incoming) {
  const existing = new Map(state.tweaks.map((tweak) => [tweak.name, tweak]));
  const nextTweaks = incoming.map((next) => {
    const current = existing.get(next.name);

    if (
      current &&
      (state.pending.has(next.name) || state.inFlight.has(next.name))
    ) {
      return { ...next, value: current.value };
    }

    const fields = state.rows.get(next.name);
    if (
      current &&
      fields?.selection !== document.activeElement &&
      Object.values(fields ?? {}).includes(document.activeElement)
    ) {
      return { ...next, value: current.value };
    }

    return next;
  });

  if (!sameTweakShape(state.tweaks, nextTweaks)) {
    state.tweaks = nextTweaks;
    renderTweaks();
    return;
  }

  for (const next of nextTweaks) {
    const current = existing.get(next.name);
    if (current && current.value !== next.value) {
      current.value = next.value;
      updateTweakRow(current);
    }
  }

  updateResetButton();
}

function closeTweakStream() {
  state.eventSource?.close();
  state.eventSource = undefined;
}

function openTweakStream() {
  closeTweakStream();

  if (isMockMode || typeof EventSource === "undefined") return;

  const source = new EventSource("/tweaks/events");
  state.eventSource = source;

  source.addEventListener("tweaks", (event) => {
    if (state.eventSource !== source || state.switching) return;

    try {
      const result = JSON.parse(event.data);
      applyTweakSnapshot(result.tweaks);
      setError();
      setStatus("connected", "Connected");
    } catch (error) {
      setError(error.message);
      setStatus("error", "Invalid tweak update");
    }
  });

  source.addEventListener("error", () => {
    if (state.eventSource !== source || state.switching) return;
    setStatus("connecting", "Reconnecting…");
  });
}

function scheduleRefresh() {
  clearTimeout(state.pollTimer);
  state.pollTimer = setTimeout(() => {
    if (!document.hidden) void refreshCurrent();
    else scheduleRefresh();
  }, 2_500);
  state.pollTimer.unref?.();
}

async function refreshCurrent() {
  if (state.refreshing || state.saving || state.switching) {
    scheduleRefresh();
    return;
  }

  state.refreshing = true;

  try {
    const result = await request("/apps");
    const previousId = state.selectedAppId;
    state.apps = result.apps;
    state.selectedAppId = result.selectedAppId ?? undefined;
    renderApps();

    if (!state.selectedAppId) {
      showEmptyState();
      return;
    }

    if (previousId !== state.selectedAppId) {
      await load({ refreshApps: false });
      return;
    }

    if (!state.eventSource) {
      applyTweakSnapshot((await request("/tweaks")).tweaks);
    }

    setError();
    setStatus("connected", "Connected");
  } catch (error) {
    setError(error.message);
    setStatus("error", "Disconnected");
  } finally {
    state.refreshing = false;
    scheduleRefresh();
  }
}

async function load({ refreshApps = true } = {}) {
  setStatus("connecting", "Connecting");

  try {
    if (refreshApps) {
      const discovery = await request("/apps");
      state.apps = discovery.apps;
      state.selectedAppId = discovery.selectedAppId ?? undefined;
      renderApps();
    }

    if (!state.selectedAppId) {
      showEmptyState();
      return;
    }

    const [app, result] = await Promise.all([
      request("/app"),
      request("/tweaks"),
    ]);

    const selected = state.apps.find((candidate) => candidate.id === state.selectedAppId);
    updateAppIdentity({ ...selected, ...app });
    state.tweaks = result.tweaks;
    renderTweaks();
    openTweakStream();
    setError();
    setStatus("connected", "Connected");

    if (isMockMode && refreshApps) setAppMenuOpen(true);
  } catch (error) {
    setError(error.message);
    setStatus("error", "Disconnected");
  } finally {
    scheduleRefresh();
  }
}

async function selectApp(id) {
  if (state.switching) return;

  if (id === state.selectedAppId) {
    setAppMenuOpen(false);
    return;
  }

  state.switching = true;
  closeTweakStream();
  setAppMenuOpen(false);
  renderApps();
  updateResetButton();

  try {
    clearTimeout(state.timer);

    while (state.saving || state.pending.size > 0) {
      if (!state.saving) {
        await flushPending();
      } else {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
    }

    const result = await request("/apps/selection", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id }),
    });

    state.selectedAppId = result.app.id;
    renderApps();
    await load({ refreshApps: false });
  } catch (error) {
    setError(error.message);
    setStatus("error", "Could not switch apps");
  } finally {
    state.switching = false;
    renderApps();
    updateResetButton();
  }
}

async function resetTweaks() {
  clearTimeout(state.timer);
  state.pending.clear();
  state.saving = true;
  setStatus("connected", "Resetting…");
  updateResetButton();

  try {
    const values = Object.fromEntries(
      state.tweaks.map((tweak) => [tweak.name, tweak.default]),
    );

    const result = await request("/tweaks", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ values }),
    });

    await reloadTweaks();
    const error = updateError(result);
    if (error) {
      setError(error);
      setStatus("error", "Some resets failed");
    } else {
      setError();
      setStatus("connected", "Connected");
    }
  } catch (error) {
    setError(error.message);
    setStatus("error", "Reset failed");
  } finally {
    state.saving = false;
    updateResetButton();
  }
}

elements.appPicker.addEventListener("click", () => {
  setAppMenuOpen(!state.menuOpen);
});

if (typeof window !== "undefined") {
  window.addEventListener("pointerdown", (event) => {
    const picker = elements.appPicker.parentElement;

    if (state.menuOpen && picker && !picker.contains(event.target)) {
      setAppMenuOpen(false);
    }
  });

  window.addEventListener("keydown", (event) => {
    if (state.menuOpen && event.key === "Escape") {
      setAppMenuOpen(false);
      elements.appPicker.focus();
    }
  });
}

elements.reset.addEventListener("click", resetTweaks);

elements.appIcon.addEventListener("error", (event) => {
  event.currentTarget.hidden = true;
});

load();
