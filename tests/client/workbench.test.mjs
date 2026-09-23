import test from "node:test";
import assert from "node:assert/strict";

import {
  GRID_DEFAULTS,
  gridPattern,
  installWorkbenchPreferences,
  normalizeGridPreferences,
} from "../../lab/src/hydronium_lab/client/workbench.js";

test("Workbench grid preferences normalize unsafe persisted values", () => {
  assert.deepEqual(normalizeGridPreferences({
    enabled: false,
    color: "#ABCDEF",
    width: 2,
    height: 999,
    shape: "hexagonal",
  }), {
    enabled: false,
    color: "#abcdef",
    width: 8,
    height: 160,
    shape: "hexagonal",
  });
  assert.deepEqual(normalizeGridPreferences({ color: "red", shape: "triangles" }), GRID_DEFAULTS);
});

test("Workbench creates square and real hexagonal grid patterns", () => {
  const square = gridPattern({ width: 20, height: 30, color: "#123456" });
  assert.match(square.image, /linear-gradient/);
  assert.equal(square.size, "20px 30px");

  const hexagonal = gridPattern({ shape: "hexagonal", width: 20, height: 30, color: "#123456" });
  assert.match(hexagonal.image, /^url\("data:image\/svg\+xml,/);
  assert.match(decodeURIComponent(hexagonal.image), /<polygon/);
  assert.equal(hexagonal.size, "30px 30px");
});

test("Workbench applies, persists, and independently resets grid settings", () => {
  class Control {
    constructor(dataset = {}) {
      this.dataset = dataset;
      this.style = {};
      this.listeners = new Map();
      this.value = "";
      this.checked = false;
    }
    addEventListener(name, handler) { this.listeners.set(name, handler); }
    removeEventListener(name) { this.listeners.delete(name); }
    emit(name) { this.listeners.get(name)?.({ target: this }); }
  }

  const roles = Object.fromEntries([
    "grid", "grid-enabled", "grid-color", "grid-width", "grid-height", "grid-shape",
  ].map((role) => [role, new Control()]));
  const resets = Object.keys(GRID_DEFAULTS).map((key) => new Control({ labGridReset: key }));
  const root = {
    querySelector(selector) {
      const match = selector.match(/^\[data-lab-(.+)\]$/);
      return match ? roles[match[1]] : null;
    },
    querySelectorAll(selector) { return selector === "[data-lab-grid-reset]" ? resets : []; },
  };
  const preferences = { theme: "midnight", grid: { enabled: false, width: 32, height: 18, shape: "hexagonal" } };
  const patches = [];
  const controller = installWorkbenchPreferences({ root, preferences, persist: (patch) => patches.push(patch) });

  assert.equal(roles.grid.dataset.gridEnabled, "false");
  assert.equal(roles.grid.dataset.gridShape, "hexagonal");
  assert.equal(roles["grid-width"].value, "32");
  assert.equal(preferences.theme, "midnight");

  roles["grid-width"].value = "80";
  roles["grid-width"].emit("change");
  assert.equal(controller.grid.width, 80);
  assert.equal(patches.at(-1).grid.width, 80);

  resets.find((button) => button.dataset.labGridReset === "width").emit("click");
  assert.equal(controller.grid.width, GRID_DEFAULTS.width);
  assert.equal(controller.grid.height, 18);
  assert.equal(preferences.theme, "midnight");

  controller.destroy();
  assert.equal(roles["grid-width"].listeners.size, 0);
});
