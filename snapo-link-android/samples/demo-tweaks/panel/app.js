const state = {
  tweaks: [],
  rows: new Map(),
  pending: new Map(),
  timer: undefined,
  saving: false,
};

const elements = {
  appName: document.querySelector("#app-name"),
  packageName: document.querySelector("#package-name"),
  status: document.querySelector("#connection-status"),
  statusText: document.querySelector("#status-text"),
  error: document.querySelector("#error-message"),
  reset: document.querySelector("#reset-button"),
  refresh: document.querySelector("#refresh-button"),
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

async function request(path, options) {
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

function updateResetButton() {
  elements.reset.disabled =
    state.saving ||
    state.tweaks.length === 0 ||
    state.tweaks.every((tweak) => tweak.value === tweak.default);
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
}

function applyAccent() {
  const accent = state.tweaks.find(
    (tweak) => tweak.name === "Accent color" && tweak.type === "color",
  );

  if (accent) {
    document.documentElement.style.setProperty("--accent", accent.value);
  }
}

function updateValue(tweak, value, delay = 75) {
  tweak.value = value;
  state.pending.set(tweak.name, value);
  updateTweakRow(tweak);
  updateResetButton();
  applyAccent();
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

    setError();
    setStatus("connected", "Connected");
  } catch (error) {
    setError(error.message);
    setStatus("error", "Update failed");
    await reloadTweaks();
  } finally {
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
  const actions = node("div", "tweak-actions");
  const reset = node("button", "tweak-reset", "Reset");
  reset.type = "button";
  reset.hidden = tweak.value === tweak.default;
  reset.setAttribute("aria-label", `Reset ${tweak.name}`);
  reset.addEventListener("click", () => {
    updateValue(tweak, tweak.default, 0);
  });

  actions.append(reset);
  line.append(node("span", "tweak-label", tweak.name), actions);
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

    const labels = node("div", "range-labels");
    labels.append(
      node("span", undefined, numberText(tweak.min)),
      node("span", undefined, numberText(tweak.max)),
    );
    row.append(slider, labels);
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
    default:
      return null;
  }
}

function sectionFor(tweak) {
  if (/animation|duration|spring|damping|stiffness|motion/i.test(tweak.name)) {
    return "motion";
  }

  if (/font|text|color|background|accent|preview/i.test(tweak.name)) {
    return "appearance";
  }

  return "other";
}

function renderTweaks() {
  state.rows.clear();

  for (const name of ["appearance", "motion", "other"]) {
    const section = document.querySelector(`#${name}-section`);
    const list = document.querySelector(`#${name}-tweaks`);
    const count = document.querySelector(`#${name}-count`);
    const tweaks = state.tweaks.filter((tweak) => sectionFor(tweak) === name);

    if (count) count.textContent = String(tweaks.length);
    list.replaceChildren(
      ...tweaks.map(makeTweak).filter((tweak) => tweak !== null),
    );
    section.hidden = list.childElementCount === 0;
  }

  applyAccent();
  updateResetButton();
}

async function reloadTweaks() {
  const result = await request("/tweaks");
  state.tweaks = result.tweaks;
  renderTweaks();
}

async function load() {
  setStatus("connecting", "Connecting");

  try {
    const [app, result] = await Promise.all([
      request("/app"),
      request("/tweaks"),
    ]);

    elements.appName.textContent = app.name;
    elements.packageName.textContent = app.packageName;
    document.title = `${app.name} · Snap-O Tweaks`;
    state.tweaks = result.tweaks;
    renderTweaks();
    setError();
    setStatus("connected", "Connected");
  } catch (error) {
    setError(error.message);
    setStatus("error", "Disconnected");
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

    await request("/tweaks", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ values }),
    });

    await reloadTweaks();
    setError();
    setStatus("connected", "Connected");
  } catch (error) {
    setError(error.message);
    setStatus("error", "Reset failed");
  } finally {
    state.saving = false;
    updateResetButton();
  }
}

elements.refresh.addEventListener("click", load);
elements.reset.addEventListener("click", resetTweaks);

document.querySelector(".app-icon").addEventListener("error", (event) => {
  event.currentTarget.hidden = true;
});

load();
