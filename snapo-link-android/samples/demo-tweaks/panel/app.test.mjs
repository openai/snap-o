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
  if (element.getAttribute("aria-label") === label) return element;

  for (const child of element.children) {
    const result = findInput(child, label);
    if (result) return result;
  }

  return null;
}

function makeDocument() {
  const selectors = [
    "#app-name",
    "#package-name",
    "#connection-status",
    "#status-text",
    "#error-message",
    "#reset-button",
    "#refresh-button",
    "#appearance-section",
    "#appearance-tweaks",
    "#appearance-count",
    "#motion-section",
    "#motion-tweaks",
    "#motion-count",
    "#other-section",
    "#other-tweaks",
    "#other-count",
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
      },
    },
    properties,
    createElement(tag) {
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
    assert.equal(document.querySelector("#status-text").textContent, "Connected");
    assert.equal(
      document.querySelector("#connection-status").getAttribute("aria-label"),
      "Connected",
    );
    assert.equal(document.querySelector("#appearance-section").hidden, false);
    assert.equal(document.querySelector("#motion-section").hidden, false);
    assert.equal(document.querySelector("#other-section").hidden, true);
    assert.equal(
      document.querySelector("#appearance-tweaks").childElementCount,
      6,
    );
    assert.equal(document.querySelector("#motion-tweaks").childElementCount, 4);
    assert.equal(document.querySelector("#appearance-count").textContent, "6");
    assert.equal(document.querySelector("#motion-count").textContent, "4");
    assert.equal(document.properties.get("--accent"), "#5468FF");
    assert.equal(document.querySelector("#reset-button").disabled, true);

    const appearance = document.querySelector("#appearance-tweaks");
    const motion = document.querySelector("#motion-tweaks");

    const fontSize = findInput(appearance, "Font size");
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
    assert.equal(document.properties.get("--accent"), "#3B82F6");
    assert.equal(document.querySelector("#reset-button").disabled, false);

    const resetAccent = findInput(appearance, "Reset Accent color");
    assert.equal(resetAccent.hidden, false);
    await resetAccent.emit("click");
    await delay(0);
    assert.deepEqual(patches.at(-1), { "Accent color": "#5468FF" });
    assert.equal(resetAccent.hidden, true);
    assert.equal(document.properties.get("--accent"), "#5468FF");

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
    assert.equal(document.properties.get("--accent"), "#5468FF");
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

    const appearance = document.querySelector("#appearance-tweaks");
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
    assert.equal(document.properties.get("--accent"), "#3B82F6");
  } finally {
    if (finishFirstRequest) {
      finishFirstRequest();
      await delay(0);
    }

    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});
