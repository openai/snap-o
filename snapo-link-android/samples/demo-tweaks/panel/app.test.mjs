import assert from "node:assert/strict";
import { setTimeout as delay } from "node:timers/promises";
import { test } from "node:test";

const descriptors = [
  {
    name: "Font size",
    type: "int",
    default: 36,
    value: 36,
    min: 16,
    max: 72,
    step: 1,
  },
  {
    name: "Font weight",
    type: "int",
    default: 600,
    value: 600,
    min: 100,
    max: 900,
    step: 100,
  },
  {
    name: "Text color",
    type: "color",
    default: "#18212F",
    value: "#18212F",
  },
  {
    name: "Background color",
    type: "color",
    default: "#F7F8FA",
    value: "#F7F8FA",
  },
  {
    name: "Accent color",
    type: "color",
    default: "#5468FF",
    value: "#5468FF",
  },
  {
    name: "Animation duration",
    type: "int",
    default: 400,
    value: 400,
    min: 100,
    max: 1500,
    step: 50,
  },
  {
    name: "Spring stiffness",
    type: "float",
    default: 280,
    value: 280,
    min: 80,
    max: 800,
    step: 20,
  },
  {
    name: "Spring damping",
    type: "float",
    default: 0.7,
    value: 0.7,
    min: 0.1,
    max: 1,
    step: 0.05,
  },
  {
    name: "Use spring",
    type: "boolean",
    default: true,
    value: true,
  },
  {
    name: "Preview text",
    type: "string",
    default: "Make it feel right.",
    value: "Make it feel right.",
  },
];

const demoApp = {
  id: "PIXEL123:com.openai.snapo.demo.tweaks",
  name: "Snap-O Tweaks Demo",
  packageName: "com.openai.snapo.demo.tweaks",
  deviceName: "Pixel 9 Pro XL",
  deviceSerial: "PIXEL123",
};

class FakeElement {
  constructor(tag = "div") {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.dataset = {};
    this.attributes = new Map();
    this.listeners = new Map();
    this.hidden = false;
    this.disabled = false;
    this.value = "";
    this.checked = false;
    this.textContent = "";
  }

  get childElementCount() {
    return this.children.length;
  }

  get validity() {
    const value = Number(this.value);

    if (this.value === "" || !Number.isFinite(value)) {
      return { valid: false };
    }

    if (this.min !== undefined && value < Number(this.min)) {
      return { valid: false };
    }

    if (this.max !== undefined && value > Number(this.max)) {
      return { valid: false };
    }

    if (this.step !== undefined && this.step !== "any") {
      const minimum = this.min === undefined ? 0 : Number(this.min);
      const position = (value - minimum) / Number(this.step);

      if (Math.abs(position - Math.round(position)) > 1e-8) {
        return { valid: false };
      }
    }

    return { valid: true };
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  getAttribute(name) {
    return this.attributes.get(name) ?? null;
  }

  removeAttribute(name) {
    this.attributes.delete(name);
  }

  append(...elements) {
    this.children.push(...elements);
  }

  replaceChildren(...elements) {
    this.children = [...elements];
  }

  addEventListener(name, listener) {
    const listeners = this.listeners.get(name) ?? [];
    listeners.push(listener);
    this.listeners.set(name, listeners);
  }

  async emit(name) {
    for (const listener of this.listeners.get(name) ?? []) {
      await listener({ currentTarget: this });
    }
  }
}

function findInput(element, label) {
  if (!element) return null;
  if (element.getAttribute("aria-label") === label) return element;

  for (const child of element.children) {
    const result = findInput(child, label);
    if (result) return result;
  }

  return null;
}

function findAppChoice(document, app, view = "Tweaks") {
  return findInput(
    document.querySelector("#app-list"),
    `${app.name}, ${view}, ${app.deviceName}`,
  );
}

function findSection(document, name = "") {
  return document
    .querySelector("#tweak-sections")
    .children.flatMap((column) => column.children)
    .find((section) => section.dataset.section === name) ?? null;
}

function findTweakList(document, name = "") {
  const section = findSection(document, name);
  return section?.children.at(-1) ?? null;
}

function visibleSections(document) {
  return document
    .querySelector("#tweak-sections")
    .children.flatMap((column) => column.children)
    .sort((left, right) => Number(left.dataset.order) - Number(right.dataset.order))
    .map((section) => section.dataset.section);
}

function visibleColumnSections(document) {
  return document
    .querySelector("#tweak-sections")
    .children.map((column) => column.children.map((section) => section.dataset.section));
}

function visibleLabels(document, name = "") {
  const list = findTweakList(document, name);

  return list?.children.map(
    (row) => row.children[0].children[0].children[0].textContent,
  ) ?? [];
}

function makeDocument() {
  const selectors = [
    "#app-picker",
    "#app-chevron",
    "#app-list",
    "#app-name",
    "#package-name",
    "#device-name",
    "#connection-status",
    "#status-text",
    "#error-message",
    "#empty-state",
    "#reset-button",
    "#tweak-sections",
    ".app-icon",
  ];
  const elements = new Map(
    selectors.map((selector) => [selector, new FakeElement()]),
  );
  const properties = new Map();

  return {
    elements,
    documentElement: {
      style: {
        setProperty(name, value) {
          properties.set(name, value);
        },
        removeProperty(name) {
          properties.delete(name);
        },
      },
    },
    properties,
    createElement(tag) {
      return new FakeElement(tag);
    },
    createElementNS(_namespace, tag) {
      return new FakeElement(tag);
    },
    querySelector(selector) {
      return elements.get(selector) ?? null;
    },
  };
}

function jsonResponse(payload, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return structuredClone(payload);
    },
  };
}

test("browser panel renders, streams, validates, and resets live tweaks", async () => {
  const document = makeDocument();
  const tweaks = structuredClone(descriptors);
  const patches = [];
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;

  globalThis.document = document;
  globalThis.fetch = async (pathname, options) => {
    if (pathname === "/apps") {
      return jsonResponse({
        apps: [demoApp],
        selectedAppId: demoApp.id,
      });
    }

    if (pathname === "/app") {
      return jsonResponse({
        name: "Snap-O Tweaks Demo",
        packageName: "com.openai.snapo.demo.tweaks",
      });
    }

    if (pathname === "/tweaks" && options?.method === "PATCH") {
      const { values } = JSON.parse(options.body);
      patches.push(values);

      for (const tweak of tweaks) {
        if (Object.hasOwn(values, tweak.name)) {
          tweak.value = values[tweak.name];
        }
      }

      return jsonResponse({
        tweaks: Object.entries(values).map(([name, value]) => ({
          name,
          value,
        })),
      });
    }

    if (pathname === "/tweaks") {
      return jsonResponse({ tweaks });
    }

    return jsonResponse({ error: "Not found." }, 404);
  };

  try {
    await import(`./app.js?browser-test=${Date.now()}`);
    await delay(0);

    assert.equal(
      document.querySelector("#app-name").textContent,
      "Snap-O Tweaks Demo",
    );
    assert.equal(document.title, "Snap-O Tweaks Demo · Snap-O Tweaks");
    assert.equal(
      document.querySelector("#package-name").textContent,
      "com.openai.snapo.demo.tweaks",
    );
    assert.equal(document.querySelector("#device-name").textContent, "Pixel 9 Pro XL");
    assert.equal(document.querySelector("#app-picker").disabled, true);
    assert.equal(document.querySelector("#app-chevron").hidden, true);
    assert.equal(document.querySelector("#app-picker").dataset.available, "true");
    assert.equal(document.querySelector("#app-picker").dataset.multiple, "false");
    assert.equal(
      document.querySelector("#app-picker").getAttribute("aria-expanded"),
      "false",
    );
    assert.equal(document.querySelector("#app-list").childElementCount, 2);
    assert.ok(findAppChoice(document, demoApp));
    assert.equal(document.querySelector("#app-list").hidden, true);
    assert.equal(document.querySelector("#empty-state").hidden, true);
    assert.equal(document.querySelector("#status-text").textContent, "Connected");
    assert.equal(
      document.querySelector("#connection-status").getAttribute("aria-label"),
      "Connected",
    );
    assert.equal(document.querySelector("#tweak-sections").childElementCount, 1);
    assert.equal(findTweakList(document).childElementCount, 10);
    assert.equal(document.properties.has("--accent"), false);
    assert.equal(document.querySelector("#reset-button").disabled, true);

    const appearance = findTweakList(document);
    const motion = appearance;

    const fontSize = findInput(appearance, "Font size");
    const fontSizeRow = appearance.children[0];
    const fontSizeLine = fontSizeRow.children[0];
    const fontSizeContent = fontSizeLine.children[0];

    assert.equal(fontSizeRow.children.length, 2);
    assert.equal(fontSizeContent.children[0].textContent, "Font size");
    assert.equal(
      fontSizeContent.children[1].children[0].getAttribute("aria-label"),
      "Font size value",
    );
    assert.equal(fontSizeLine.children[1].getAttribute("aria-label"), "Reset Font size");
    assert.equal(fontSize.min, "16");
    assert.equal(fontSize.max, "72");

    fontSize.value = "48";
    await fontSize.emit("input");
    assert.equal(findInput(appearance, "Font size value").value, "48");

    const fontWeight = findInput(appearance, "Font weight value");
    fontWeight.value = "700";
    await fontWeight.emit("input");

    const textColor = findInput(appearance, "Text color color");
    textColor.value = "#102030";
    await textColor.emit("input");

    const background = findInput(appearance, "Background color hex");
    background.value = "#f3f4f6";
    await background.emit("input");

    const accent = findInput(appearance, "Accent color color");
    accent.value = "#3b82f6";
    await accent.emit("input");

    const duration = findInput(motion, "Animation duration");
    duration.value = "550";
    await duration.emit("input");

    const stiffness = findInput(motion, "Spring stiffness");
    stiffness.value = "400";
    await stiffness.emit("input");

    const damping = findInput(motion, "Spring damping value");
    damping.value = "0.8";
    await damping.emit("input");

    const spring = findInput(motion, "Use spring");
    spring.checked = false;
    await spring.emit("change");

    const preview = findInput(appearance, "Preview text");
    preview.value = "A calmer direction.";
    await preview.emit("input");

    await delay(180);

    assert.ok(patches.length > 0);
    assert.deepEqual(Object.assign({}, ...patches), {
      "Font size": 48,
      "Font weight": 700,
      "Text color": "#102030",
      "Background color": "#F3F4F6",
      "Accent color": "#3B82F6",
      "Animation duration": 550,
      "Spring stiffness": 400,
      "Spring damping": 0.8,
      "Use spring": false,
      "Preview text": "A calmer direction.",
    });
    assert.equal(document.properties.has("--accent"), false);
    assert.equal(document.querySelector("#reset-button").disabled, false);

    const resetAccent = findInput(appearance, "Reset Accent color");
    assert.equal(resetAccent.hidden, false);
    await resetAccent.emit("click");
    await delay(0);
    assert.deepEqual(patches.at(-1), { "Accent color": "#5468FF" });
    assert.equal(resetAccent.hidden, true);
    assert.equal(document.properties.has("--accent"), false);

    const patchesBeforeInvalid = patches.length;
    fontWeight.value = "701";
    await fontWeight.emit("input");
    assert.equal(fontWeight.getAttribute("aria-invalid"), "true");
    await delay(100);
    assert.equal(patches.length, patchesBeforeInvalid);

    const patchesBeforeReset = patches.length;
    await document.querySelector("#reset-button").emit("click");

    assert.equal(patches.length, patchesBeforeReset + 1);
    assert.deepEqual(
      patches.at(-1),
      Object.fromEntries(descriptors.map((tweak) => [tweak.name, tweak.default])),
    );
    assert.equal(document.querySelector("#reset-button").disabled, true);
    assert.equal(document.properties.has("--accent"), false);
    assert.equal(document.querySelector("#status-text").textContent, "Connected");
    assert.equal(document.querySelector("#error-message").hidden, true);
  } finally {
    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});

test("sliders stream immediately and wait for each request before sending the latest values", async () => {
  const document = makeDocument();
  const tweaks = structuredClone(descriptors);
  const patches = [];
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;
  let requestsInFlight = 0;
  let maximumRequestsInFlight = 0;
  let finishFirstRequest;

  globalThis.document = document;
  globalThis.fetch = async (pathname, options) => {
    if (pathname === "/apps") {
      return jsonResponse({
        apps: [demoApp],
        selectedAppId: demoApp.id,
      });
    }

    if (pathname === "/app") {
      return jsonResponse({
        name: "Snap-O Tweaks Demo",
        packageName: "com.openai.snapo.demo.tweaks",
      });
    }

    if (pathname === "/tweaks" && options?.method === "PATCH") {
      const { values } = JSON.parse(options.body);
      patches.push(values);
      requestsInFlight += 1;
      maximumRequestsInFlight = Math.max(
        maximumRequestsInFlight,
        requestsInFlight,
      );

      const finish = () => {
        for (const tweak of tweaks) {
          if (Object.hasOwn(values, tweak.name)) {
            tweak.value = values[tweak.name];
          }
        }

        requestsInFlight -= 1;
        return jsonResponse({
          tweaks: Object.entries(values).map(([name, value]) => ({
            name,
            value,
          })),
        });
      };

      if (patches.length === 1) {
        return new Promise((resolve) => {
          finishFirstRequest = () => resolve(finish());
        });
      }

      return finish();
    }

    if (pathname === "/tweaks") {
      return jsonResponse({ tweaks });
    }

    return jsonResponse({ error: "Not found." }, 404);
  };

  try {
    await import(`./app.js?slider-stream-test=${Date.now()}`);
    await delay(0);

    const appearance = findTweakList(document);
    const slider = findInput(appearance, "Font size");

    slider.value = "37";
    await slider.emit("input");

    assert.deepEqual(patches, [{ "Font size": 37 }]);
    assert.equal(requestsInFlight, 1);
    assert.equal(document.querySelector("#status-text").textContent, "Saving…");
    assert.equal(
      document.querySelector("#connection-status").getAttribute("aria-label"),
      "Saving…",
    );

    for (const value of ["38", "39", "40"]) {
      slider.value = value;
      await slider.emit("input");
    }

    const fontWeight = findInput(appearance, "Font weight");
    fontWeight.value = "700";
    await fontWeight.emit("input");

    const color = findInput(appearance, "Accent color color");
    color.value = "#3b82f6";
    await color.emit("input");

    await delay(10);

    assert.deepEqual(patches, [{ "Font size": 37 }]);
    assert.equal(requestsInFlight, 1);

    const finish = finishFirstRequest;
    finishFirstRequest = undefined;
    finish();
    await delay(10);

    assert.deepEqual(patches, [
      { "Font size": 37 },
      {
        "Font size": 40,
        "Font weight": 700,
        "Accent color": "#3B82F6",
      },
    ]);
    assert.equal(maximumRequestsInFlight, 1);
    assert.equal(requestsInFlight, 0);
    assert.equal(document.querySelector("#status-text").textContent, "Connected");
    assert.equal(document.properties.has("--accent"), false);
  } finally {
    if (finishFirstRequest) {
      finishFirstRequest();
      await delay(0);
    }

    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});

test("groups tweaks only by explicit folder paths and patches their full names", async () => {
  const document = makeDocument();
  const tweaks = [
    { ...descriptors[0], name: "Typography/Font size" },
    { ...descriptors[1], name: "Typography/Font weight" },
    { ...descriptors[2], name: "Colors/Text" },
    { ...descriptors[5], name: "Motion/Duration" },
    { ...descriptors[8], name: "Enabled" },
    { ...descriptors[5], name: "Animation duration" },
  ];
  const patches = [];
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;

  globalThis.document = document;
  globalThis.fetch = async (pathname, options) => {
    if (pathname === "/apps") {
      return jsonResponse({ apps: [demoApp], selectedAppId: demoApp.id });
    }

    if (pathname === "/app") {
      return jsonResponse({ name: demoApp.name, packageName: demoApp.packageName });
    }

    if (pathname === "/tweaks" && options?.method === "PATCH") {
      const { values } = JSON.parse(options.body);
      patches.push(values);

      for (const tweak of tweaks) {
        if (Object.hasOwn(values, tweak.name)) tweak.value = values[tweak.name];
      }

      return jsonResponse({
        tweaks: Object.entries(values).map(([name, value]) => ({ name, value })),
      });
    }

    if (pathname === "/tweaks") return jsonResponse({ tweaks });
    return jsonResponse({ error: "Not found." }, 404);
  };

  try {
    await import(`./app.js?explicit-folder-test=${Date.now()}`);
    await delay(0);

    assert.deepEqual(visibleSections(document), ["Typography", "Colors", "Motion", ""]);
    assert.deepEqual(visibleLabels(document, "Typography"), ["Font size", "Font weight"]);
    assert.deepEqual(visibleLabels(document, "Colors"), ["Text"]);
    assert.deepEqual(visibleLabels(document, "Motion"), ["Duration"]);
    assert.deepEqual(visibleLabels(document), ["Enabled", "Animation duration"]);

    const typography = findTweakList(document, "Typography");
    const slider = findInput(typography, "Typography/Font size");
    slider.value = "48";
    await slider.emit("input");
    await delay(0);

    assert.deepEqual(patches, [{ "Typography/Font size": 48 }]);
  } finally {
    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});

test("restores section and tweak order as folders disappear and reappear", async () => {
  const document = makeDocument();
  const typography = { ...descriptors[0], name: "Typography/Font size" };
  const enabled = { ...descriptors[8], name: "Motion/Enabled" };
  const duration = { ...descriptors[5], name: "Motion/Duration" };
  const stiffness = { ...descriptors[6], name: "Motion/Spring stiffness" };
  const accent = { ...descriptors[4], name: "Colors/Accent" };
  let tweaks = [typography, enabled, duration, stiffness, accent];
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;

  globalThis.document = document;
  globalThis.fetch = async (pathname) => {
    if (pathname === "/apps") {
      return jsonResponse({ apps: [demoApp], selectedAppId: demoApp.id });
    }

    if (pathname === "/app") {
      return jsonResponse({ name: demoApp.name, packageName: demoApp.packageName });
    }

    if (pathname === "/tweaks") return jsonResponse({ tweaks });
    return jsonResponse({ error: "Not found." }, 404);
  };

  try {
    await import(`./app.js?stable-folder-order-test=${Date.now()}`);
    await delay(0);

    assert.deepEqual(visibleSections(document), ["Typography", "Motion", "Colors"]);
    assert.deepEqual(visibleColumnSections(document), [
      ["Typography", "Colors"],
      ["Motion"],
    ]);
    assert.deepEqual(visibleLabels(document, "Motion"), [
      "Enabled",
      "Duration",
      "Spring stiffness",
    ]);

    tweaks = [accent, enabled, typography];
    await delay(2_600);
    assert.deepEqual(visibleSections(document), ["Typography", "Motion", "Colors"]);
    assert.deepEqual(visibleLabels(document, "Motion"), ["Enabled"]);

    tweaks = [accent, typography];
    await delay(2_600);
    assert.deepEqual(visibleSections(document), ["Typography", "Colors"]);
    assert.deepEqual(visibleColumnSections(document), [
      ["Typography", "Colors"],
      [],
    ]);

    tweaks = [accent, stiffness, duration, enabled, typography];
    await delay(2_600);
    assert.deepEqual(visibleSections(document), ["Typography", "Motion", "Colors"]);
    assert.deepEqual(visibleColumnSections(document), [
      ["Typography", "Colors"],
      ["Motion"],
    ]);
    assert.deepEqual(visibleLabels(document, "Motion"), [
      "Enabled",
      "Duration",
      "Spring stiffness",
    ]);
    assert.equal(document.properties.has("--accent"), false);
  } finally {
    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});

test("remembers folder order independently for each selected app", async () => {
  const document = makeDocument();
  const secondApp = {
    id: "PIXEL123:com.example.colors",
    name: "Color Study",
    packageName: "com.example.colors",
    deviceName: "Pixel 9 Pro XL",
    deviceSerial: "PIXEL123",
  };
  const firstFont = { ...descriptors[0], name: "Typography/Font size" };
  const firstMotion = { ...descriptors[5], name: "Motion/Duration" };
  const secondColor = { ...descriptors[4], name: "Colors/Accent" };
  const secondFont = { ...descriptors[1], name: "Typography/Font weight" };
  let firstTweaks = [firstFont, firstMotion];
  let selectedId = demoApp.id;
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;

  globalThis.document = document;
  globalThis.fetch = async (pathname, options) => {
    if (pathname === "/apps") {
      return jsonResponse({
        apps: [demoApp, secondApp],
        selectedAppId: selectedId,
      });
    }

    if (pathname === "/apps/selection" && options?.method === "PUT") {
      selectedId = JSON.parse(options.body).id;
      return jsonResponse({
        app: selectedId === secondApp.id ? secondApp : demoApp,
      });
    }

    if (pathname === "/app") {
      const selected = selectedId === secondApp.id ? secondApp : demoApp;
      return jsonResponse({ name: selected.name, packageName: selected.packageName });
    }

    if (pathname === "/tweaks") {
      return jsonResponse({
        tweaks: selectedId === secondApp.id
          ? [secondColor, secondFont]
          : firstTweaks,
      });
    }

    return jsonResponse({ error: "Not found." }, 404);
  };

  try {
    await import(`./app.js?per-app-folder-order-test=${Date.now()}`);
    await delay(0);
    assert.deepEqual(visibleSections(document), ["Typography", "Motion"]);

    await document.querySelector("#app-picker").emit("click");
    await findAppChoice(document, secondApp).emit("click");
    assert.deepEqual(visibleSections(document), ["Colors", "Typography"]);
    assert.deepEqual(visibleLabels(document, "Colors"), ["Accent"]);

    firstTweaks = [firstMotion, firstFont];
    await document.querySelector("#app-picker").emit("click");
    await findAppChoice(document, demoApp).emit("click");

    assert.deepEqual(visibleSections(document), ["Typography", "Motion"]);
    assert.deepEqual(visibleLabels(document, "Typography"), ["Font size"]);
    assert.deepEqual(visibleLabels(document, "Motion"), ["Duration"]);
  } finally {
    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});

test("shows an accurate empty state when no tweaks apps are running", async () => {
  const document = makeDocument();
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;

  globalThis.document = document;
  globalThis.fetch = async (pathname) => {
    if (pathname === "/apps") {
      return jsonResponse({ apps: [], selectedAppId: null });
    }

    return jsonResponse({ error: "Not found." }, 404);
  };

  try {
    await import(`./app.js?empty-state-test=${Date.now()}`);
    await delay(0);

    assert.equal(document.querySelector("#app-picker").disabled, true);
    assert.equal(document.querySelector("#app-list").childElementCount, 0);
    assert.equal(document.querySelector("#empty-state").hidden, false);
    assert.equal(document.querySelector("#app-name").textContent, "No app selected");
    assert.equal(document.querySelector("#status-text").textContent, "No apps found");
    assert.equal(document.querySelector("#reset-button").disabled, true);
    assert.equal(document.querySelector("#error-message").hidden, true);
  } finally {
    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});

test("switches apps only after pending slider updates finish", async () => {
  const document = makeDocument();
  const secondApp = {
    id: "PIXEL123:com.example.motion",
    name: "Motion Study",
    packageName: "com.example.motion",
    deviceName: "Pixel 9 Pro XL",
    deviceSerial: "PIXEL123",
  };
  const motionTweak = {
    name: "Transition progress",
    type: "float",
    default: 0.5,
    value: 0.5,
    min: 0,
    max: 1,
    step: 0.1,
  };
  const patches = [];
  const selections = [];
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;
  let selectedId = demoApp.id;
  let finishFirstRequest;

  globalThis.document = document;
  globalThis.fetch = async (pathname, options) => {
    if (pathname === "/apps") {
      return jsonResponse({
        apps: [demoApp, secondApp],
        selectedAppId: selectedId,
      });
    }

    if (pathname === "/apps/selection" && options?.method === "PUT") {
      const { id } = JSON.parse(options.body);
      selections.push(id);
      selectedId = id;
      return jsonResponse({ app: id === secondApp.id ? secondApp : demoApp });
    }

    if (pathname === "/app") {
      const app = selectedId === secondApp.id ? secondApp : demoApp;
      return jsonResponse({ name: app.name, packageName: app.packageName });
    }

    if (pathname === "/tweaks" && options?.method === "PATCH") {
      const { values } = JSON.parse(options.body);
      patches.push({ appId: selectedId, values });

      const result = jsonResponse({
        tweaks: Object.entries(values).map(([name, value]) => ({ name, value })),
      });

      if (patches.length === 1) {
        return new Promise((resolve) => {
          finishFirstRequest = () => resolve(result);
        });
      }

      return result;
    }

    if (pathname === "/tweaks") {
      return jsonResponse({
        tweaks: selectedId === secondApp.id
          ? [motionTweak]
          : structuredClone(descriptors),
      });
    }

    return jsonResponse({ error: "Not found." }, 404);
  };

  try {
    await import(`./app.js?app-switch-test=${Date.now()}`);
    await delay(0);

    const list = document.querySelector("#app-list");
    assert.equal(list.childElementCount, 5);
    assert.equal(list.hidden, true);
    assert.equal(document.querySelector("#app-picker").disabled, false);
    assert.equal(document.querySelector("#app-chevron").hidden, false);
    assert.equal(document.querySelector("#app-picker").dataset.multiple, "true");

    await document.querySelector("#app-picker").emit("click");
    assert.equal(list.hidden, false);
    assert.equal(
      document.querySelector("#app-picker").getAttribute("aria-expanded"),
      "true",
    );

    const slider = findInput(
      findTweakList(document),
      "Font size",
    );
    slider.value = "48";
    await slider.emit("input");
    assert.deepEqual(patches, [
      { appId: demoApp.id, values: { "Font size": 48 } },
    ]);

    const switching = findAppChoice(document, secondApp).emit("click");
    await delay(5);
    assert.deepEqual(selections, []);
    assert.equal(document.querySelector("#app-name").textContent, demoApp.name);

    const finish = finishFirstRequest;
    finishFirstRequest = undefined;
    finish();
    await switching;

    assert.deepEqual(selections, [secondApp.id]);
    assert.equal(document.querySelector("#app-list").hidden, true);
    assert.equal(
      document.querySelector("#app-picker").getAttribute("aria-expanded"),
      "false",
    );
    assert.equal(document.querySelector("#app-name").textContent, secondApp.name);
    assert.equal(document.querySelector("#package-name").textContent, secondApp.packageName);
    assert.equal(document.querySelector("#tweak-sections").childElementCount, 1);
    assert.equal(findTweakList(document).childElementCount, 1);
    assert.ok(findInput(findTweakList(document), "Transition progress"));
    assert.equal(document.properties.has("--accent"), false);
    assert.equal(
      findAppChoice(document, secondApp).getAttribute("aria-pressed"),
      "true",
    );
    assert.deepEqual(patches, [
      { appId: demoApp.id, values: { "Font size": 48 } },
    ]);
  } finally {
    if (finishFirstRequest) {
      finishFirstRequest();
      await delay(0);
    }

    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});

test("automatic refresh replaces tweaks when the app changes screens", async () => {
  const document = makeDocument();
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;
  let tweaks = structuredClone(descriptors);

  globalThis.document = document;
  globalThis.fetch = async (pathname) => {
    if (pathname === "/apps") {
      return jsonResponse({ apps: [demoApp], selectedAppId: demoApp.id });
    }

    if (pathname === "/app") {
      return jsonResponse({ name: demoApp.name, packageName: demoApp.packageName });
    }

    if (pathname === "/tweaks") {
      return jsonResponse({ tweaks });
    }

    return jsonResponse({ error: "Not found." }, 404);
  };

  try {
    await import(`./app.js?screen-change-test=${Date.now()}`);
    await delay(0);
    assert.equal(findTweakList(document).childElementCount, 10);

    tweaks = [
      {
        name: "Transition duration",
        type: "int",
        default: 300,
        value: 450,
        min: 100,
        max: 1_000,
        step: 50,
      },
    ];
    await delay(2_600);

    assert.equal(document.querySelector("#tweak-sections").childElementCount, 1);
    assert.equal(findTweakList(document).childElementCount, 1);
    assert.ok(findInput(findTweakList(document), "Transition duration"));
    assert.equal(document.querySelector("#reset-button").disabled, false);
  } finally {
    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});

test("motion tweaks appear and disappear as the visibility tweak changes composition", async () => {
  const document = makeDocument();
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;
  const visibility = {
    name: "Show motion",
    type: "boolean",
    default: true,
    value: true,
  };
  const motionNames = new Set([
    "Animation duration",
    "Spring stiffness",
    "Spring damping",
    "Use spring",
  ]);

  globalThis.document = document;
  globalThis.fetch = async (pathname, options) => {
    if (pathname === "/apps") {
      return jsonResponse({ apps: [demoApp], selectedAppId: demoApp.id });
    }

    if (pathname === "/app") {
      return jsonResponse({ name: demoApp.name, packageName: demoApp.packageName });
    }

    if (pathname === "/tweaks" && options?.method === "PATCH") {
      const { values } = JSON.parse(options.body);

      if (Object.hasOwn(values, visibility.name)) {
        visibility.value = values[visibility.name];
      }

      return jsonResponse({
        tweaks: Object.entries(values).map(([name, value]) => ({ name, value })),
      });
    }

    if (pathname === "/tweaks") {
      const visibleTweaks = descriptors.filter(
        (tweak) => visibility.value || !motionNames.has(tweak.name),
      );

      return jsonResponse({
        tweaks: [...visibleTweaks, visibility],
      });
    }

    return jsonResponse({ error: "Not found." }, 404);
  };

  try {
    await import(`./app.js?composition-visibility-test=${Date.now()}`);
    await delay(0);

    let motion = findTweakList(document);
    assert.equal(motion.childElementCount, 11);
    assert.ok(findInput(motion, "Animation duration"));

    let toggle = findInput(motion, "Show motion");
    assert.ok(toggle);
    toggle.checked = false;
    await toggle.emit("change");
    await delay(2_600);

    motion = findTweakList(document);
    assert.equal(visibility.value, false);
    assert.equal(motion.childElementCount, 7);
    assert.equal(findInput(motion, "Animation duration"), null);
    assert.equal(findInput(motion, "Spring stiffness"), null);

    toggle = findInput(motion, "Show motion");
    assert.ok(toggle);
    toggle.checked = true;
    await toggle.emit("change");
    await delay(2_600);

    motion = findTweakList(document);
    assert.equal(visibility.value, true);
    assert.equal(motion.childElementCount, 11);
    assert.ok(findInput(motion, "Animation duration"));
    assert.ok(findInput(motion, "Spring stiffness"));
    assert.equal(document.querySelector("#error-message").hidden, true);
  } finally {
    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});
