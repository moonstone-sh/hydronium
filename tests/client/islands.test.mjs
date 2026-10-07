import test from "node:test";
import assert from "node:assert/strict";

import { bootIslands, hydrateIslands, luaIslands } from "../../js/packages/dom-client/src/islands.js";
import { boot } from "../../js/packages/dom-client/src/mount.js";
import * as boundaries from "../../js/packages/dom-client/src/boundary_registry.js";

globalThis.NodeFilter ??= { SHOW_COMMENT: 128 };

// Flat fake document: the nodes under one parent, in document order. Enough
// for marker discovery, ranges and nesting checks.
function fakeDocument(spec, scripts = {}) {
  const parent = { nodeType: 1, nodeName: "MAIN", removeChild(child) { const i = nodes.indexOf(child); if (i >= 0) nodes.splice(i, 1); } };
  const nodes = spec.map((item) => item.startsWith("#")
    ? { nodeType: 8, nodeValue: item.slice(1), parentNode: parent }
    : { nodeType: 1, nodeName: item.toUpperCase(), parentNode: parent });
  for (const node of nodes) {
    Object.defineProperty(node, "nextSibling", { get: () => nodes[nodes.indexOf(node) + 1] || null });
    node.compareDocumentPosition = (other) => (nodes.indexOf(other) > nodes.indexOf(node) ? 4 : 2);
  }
  const doc = {
    body: parent,
    ownerDocument: null,
    getElementById: (id) => (id in scripts ? { textContent: JSON.stringify(scripts[id]) } : null),
    createTreeWalker() {
      let index = -1;
      const comments = nodes.filter((node) => node.nodeType === 8);
      return { nextNode: () => comments[++index] || null };
    },
  };
  return { doc, nodes };
}

function fakeEngine() {
  const globals = new Map();
  const renders = [];
  return {
    renders,
    globals,
    lua: {
      global: { set(key, value) { globals.set(key, value); }, get: (key) => globals.get(key) },
      async doString(source) {
        if (source.includes("__hydronium_island_hydrate then")) {
          renders.push({ id: globals.get("__hydronium_island_id"), module: globals.get("__hydronium_island_module"),
            props: globals.get("__hydronium_island_props_src"), hydrate: globals.get("__hydronium_island_hydrate") });
        }
      },
    },
  };
}

test("luaIslands keeps browser-hydrated Lua islands only", () => {
  const plan = { islands: [
    { id: "hy:i1", interpreter: "lua", module: "A" },
    { id: "hy:i2", interpreter: "js", module: "/b.js" },
    { id: "hy:i3", interpreter: "lua", root: true, module: "views.App" },
  ] };
  assert.deepEqual(luaIslands(plan).map((island) => island.id), ["hy:i1"]);
});

test("a page without Lua islands never starts an engine or fetches modules", async () => {
  const originalDocument = globalThis.document;
  const originalFetch = globalThis.fetch;
  let fetched = false;
  globalThis.fetch = async () => { fetched = true; throw new Error("no fetch expected"); };
  globalThis.document = fakeDocument([], { __HYDRONIUM_CLIENT_PLAN__: { islands: [{ id: "hy:i1", interpreter: "js" }] } }).doc;
  try {
    let created = false;
    const result = await bootIslands({ engineProvider: { create: async () => { created = true; } } });
    assert.equal(result.lua, null);
    assert.deepEqual(await result.hydrated, []);
    assert.equal(created, false);
    assert.equal(fetched, false);
  } finally {
    globalThis.document = originalDocument;
    globalThis.fetch = originalFetch;
  }
});

test("boot accepts an entryless page and never requires a root module", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, text: async () => "return {}" });
  const { lua } = fakeEngine();
  const commands = [];
  const doString = lua.doString;
  lua.doString = async (source) => { commands.push(source); return doString(source); };
  try {
    await boot({ chunkUrls: ["/runtime.lua"], entryless: true, container: { setAttribute() {}, removeAttribute() {} },
      hydrate: true, engineProvider: { create: async () => lua } });
    assert.ok(commands.includes("__hydronium_app_module_id = nil"));
    assert.ok(commands.some((source) => source.includes("if __hydronium_app_module_id then")));
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("hydrates each top-level island in its own range, in order, with its props", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({ ok: true, text: async () => "return {}" });
  boundaries._reset();
  const { doc } = fakeDocument([
    "#hy:i:hy:i1:lua", "button", "#hy:/i:hy:i1",
    "p",
    "#hy:i:hy:i2:lua", "div", "#hy:i:hy:i3:lua", "span", "#hy:/i:hy:i3", "#hy:/i:hy:i2",
  ]);
  const engine = fakeEngine();
  try {
    const result = await hydrateIslands({
      root: doc,
      islands: [
        { id: "hy:i1", interpreter: "lua", module: "components.Counter", props: { start: 3 } },
        { id: "hy:i2", interpreter: "lua", module: "components.Panel", props: {} },
        { id: "hy:i3", interpreter: "lua", module: "components.Nested", props: {} },
      ],
      chunkUrls: ["/runtime.lua"],
      engineProvider: { create: async () => engine.lua },
    });
    assert.deepEqual(await result.hydrated, []);
    assert.deepEqual(await result.loaded, []);
    assert.deepEqual(engine.renders.map((r) => [r.id, r.module, r.hydrate]), [
      ["hy:i1", "components.Counter", true],
      ["hy:i2", "components.Panel", true],
    ], "the nested island hydrates as part of its ancestor");
    assert.match(engine.renders[0].props, /start = 3/);
    assert.deepEqual(result.islands.map((island) => island.id), ["hy:i1", "hy:i2"]);

    await result.remount();
    assert.deepEqual(engine.renders.slice(2).map((r) => [r.id, r.hydrate]), [["hy:i1", false], ["hy:i2", false]]);
  } finally {
    globalThis.fetch = originalFetch;
    boundaries._reset();
  }
});

test("a page whose islands all wait for visibility starts no VM until one is visible", async () => {
  const originalFetch = globalThis.fetch;
  const originalObserver = globalThis.IntersectionObserver;
  let reveal;
  globalThis.IntersectionObserver = class {
    constructor(callback) { reveal = () => callback([{ isIntersecting: true }]); }
    observe() {}
    disconnect() {}
  };
  globalThis.fetch = async () => ({ ok: true, text: async () => "return {}" });
  boundaries._reset();
  const { doc } = fakeDocument(["#hy:i:hy:i1:lua", "button", "#hy:/i:hy:i1"]);
  const engine = fakeEngine();
  let created = 0;
  try {
    const pending = hydrateIslands({
      root: doc,
      islands: [{ id: "hy:i1", interpreter: "lua", module: "components.Counter", props: {}, hydrate: "visible" }],
      chunkUrls: ["/runtime.lua"],
      engineProvider: { create: async () => { created++; return engine.lua; } },
    });
    await new Promise((resolve) => setTimeout(resolve, 20));
    assert.equal(created, 0, "no engine before the island is visible");
    reveal();
    const result = await pending;
    await result.hydrated;
    assert.equal(created, 1);
    assert.deepEqual(engine.renders.map((r) => r.id), ["hy:i1"]);
  } finally {
    globalThis.fetch = originalFetch;
    globalThis.IntersectionObserver = originalObserver;
    boundaries._reset();
  }
});
