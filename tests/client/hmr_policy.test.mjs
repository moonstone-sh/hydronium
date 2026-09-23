import test from "node:test";
import assert from "node:assert/strict";

import { installHmr } from "../../js/packages/dom-client/src/hmr.js";

const turn = () => new Promise((resolve) => setImmediate(resolve));

test("HMR requires explicit update policies and preserves state for hot modules", async () => {
  const originalEventSource = globalThis.EventSource;
  const originalFetch = globalThis.fetch;
  const sources = [];
  const globals = new Map();
  const reports = [];
  let reloads = 0;
  let fetches = 0;

  class FakeEventSource {
    constructor(url) {
      this.url = url;
      this.listeners = new Map();
      sources.push(this);
    }

    addEventListener(type, listener) {
      this.listeners.set(type, listener);
    }

    emit(type, data) {
      this.listeners.get(type)?.({ data });
    }

    close() {}
  }

  const lua = {
    global: {
      set(key, value) { globals.set(key, value); },
      get(key) { return globals.get(key); },
    },
    async doString() {
      globals.set("__hydronium_hmr_outcome", "hot");
      globals.set("__hydronium_hmr_families", 1);
      globals.set("__hydronium_hmr_refreshed", 1);
      globals.set("__hydronium_hmr_failed", 0);
    },
  };

  globalThis.EventSource = FakeEventSource;
  globalThis.fetch = async () => {
    fetches += 1;
    return { ok: true, text: async () => "return function() end" };
  };

  try {
    const hmr = installHmr({
      lua,
      updates: {
        "views/App.luax": { action: "hot", module: "views.App" },
        "views/Document.luax": { action: "reload" },
      },
      onUpdate: (info) => reports.push(info),
      onFullReload: () => { reloads += 1; },
    });

    sources[0].emit("changed", "views/Unknown.luax");
    sources[0].emit("reload", "fingerprint-1");
    await turn();
    assert.equal(reports.at(-1).status, "unhandled");
    assert.equal(fetches, 0);
    assert.equal(reloads, 0, "an omitted policy must not destroy the VM");

    sources[1].emit("changed", "views/App.luax");
    sources[1].emit("reload", "fingerprint-2");
    await turn();
    await turn();
    assert.equal(reports.at(-1).status, "hot-swapped");
    assert.equal(reports.at(-1).id, "views.App");
    assert.equal(fetches, 1);
    assert.equal(reloads, 0);

    sources[2].emit("changed", "views/Document.luax");
    sources[2].emit("reload", "fingerprint-3");
    await turn();
    assert.equal(reports.at(-1).status, "full-reload");
    assert.equal(reloads, 1);

    hmr.close();
  } finally {
    globalThis.EventSource = originalEventSource;
    globalThis.fetch = originalFetch;
  }
});

test("HMR fetches a revisioned module set and commits it once at a frame boundary", async () => {
  const originalEventSource = globalThis.EventSource;
  const originalFetch = globalThis.fetch;
  const sources = [];
  const globals = new Map();
  const fetched = [];
  const frames = [];
  const reports = [];
  let evaluations = 0;

  class FakeEventSource {
    constructor(url) {
      this.url = url;
      this.listeners = new Map();
      sources.push(this);
    }
    addEventListener(type, listener) { this.listeners.set(type, listener); }
    emit(type, data) { this.listeners.get(type)?.({ data }); }
    close() {}
  }

  globalThis.EventSource = FakeEventSource;
  globalThis.fetch = async (url) => {
    fetched.push(url);
    return {
      ok: true,
      headers: { get: () => null },
      text: async () => `return ${JSON.stringify(url)}`,
    };
  };

  const lua = {
    global: {
      set(key, value) { globals.set(key, value); },
      get(key) { return globals.get(key); },
    },
    async doString() {
      evaluations += 1;
      assert.equal(globals.get("__hydronium_hmr_count"), 2);
      assert.equal(globals.get("__hydronium_hmr_batch_revision"), "revision 2");
      globals.set("__hydronium_hmr_outcome", "hot");
      globals.set("__hydronium_hmr_families", 2);
      globals.set("__hydronium_hmr_refreshed", 2);
      globals.set("__hydronium_hmr_failed", 0);
    },
  };

  try {
    const hmr = installHmr({
      lua,
      updates: {
        "lib/model.lua": { action: "hot", module: "lib.model" },
        "views/App.luax": { action: "hot", module: "views.App" },
      },
      schedule: (apply) => frames.push(apply),
      onUpdate: (info) => reports.push(info),
    });

    sources[0].emit("changed", "lib/model.lua|views/App.luax");
    sources[0].emit("reload", "revision 2");
    await turn();
    await turn();

    assert.equal(fetched.length, 2, "the whole source set is fetched before commit");
    assert.equal(evaluations, 0);
    assert.equal(frames.length, 1);
    frames[0]();
    await turn();
    await turn();

    assert.equal(evaluations, 1, "one Lua evaluation commits the complete batch");
    assert.deepEqual(reports.at(-1).ids, ["lib.model", "views.App"]);
    assert.equal(reports.at(-1).revision, "revision 2");
    assert.equal(reports.at(-1).status, "hot-swapped");
    hmr.close();
  } finally {
    globalThis.EventSource = originalEventSource;
    globalThis.fetch = originalFetch;
  }
});

test("HMR reloads rather than committing sources from a different snapshot revision", async () => {
  const originalEventSource = globalThis.EventSource;
  const originalFetch = globalThis.fetch;
  const sources = [];
  let reloads = 0;
  let evaluations = 0;

  class FakeEventSource {
    constructor() { this.listeners = new Map(); sources.push(this); }
    addEventListener(type, listener) { this.listeners.set(type, listener); }
    emit(type, data) { this.listeners.get(type)?.({ data }); }
    close() {}
  }
  globalThis.EventSource = FakeEventSource;
  globalThis.fetch = async () => ({
    ok: true,
    headers: { get: (name) => name === "x-hydronium-revision" ? "newer-revision" : null },
    text: async () => "return function() end",
  });

  const lua = {
    global: { set() {}, get() { return undefined; } },
    async doString() { evaluations += 1; },
  };
  try {
    installHmr({
      lua,
      updates: { "views/App.luax": { action: "hot", module: "views.App" } },
      onFullReload: () => { reloads += 1; },
    });
    sources[0].emit("changed", "views/App.luax");
    sources[0].emit("reload", "old-revision");
    await turn();
    await turn();
    assert.equal(reloads, 1);
    assert.equal(evaluations, 0);
  } finally {
    globalThis.EventSource = originalEventSource;
    globalThis.fetch = originalFetch;
  }
});

test("HMR delegates a planned remount to the mount handle instead of reloading", async () => {
  const originalEventSource = globalThis.EventSource;
  const originalFetch = globalThis.fetch;
  const sources = [];
  let remounts = 0;
  let reloads = 0;
  class FakeEventSource {
    constructor() { this.listeners = new Map(); sources.push(this); }
    addEventListener(type, listener) { this.listeners.set(type, listener); }
    emit(type, data) { this.listeners.get(type)?.({ data }); }
    close() {}
  }
  globalThis.EventSource = FakeEventSource;
  globalThis.fetch = async () => ({ ok: true, headers: { get: () => null }, text: async () => "return {}" });
  const globals = new Map();
  const lua = {
    global: { set(key, value) { globals.set(key, value); }, get(key) { return globals.get(key); } },
    async doString() {
      globals.set("__hydronium_hmr_outcome", "remount");
      globals.set("__hydronium_hmr_families", 0);
      globals.set("__hydronium_hmr_refreshed", 0);
      globals.set("__hydronium_hmr_failed", 0);
    },
  };
  try {
    installHmr({
      lua,
      updates: { "lib/config.lua": { action: "hot", module: "lib.config" } },
      remount: async () => { remounts += 1; },
      onFullReload: () => { reloads += 1; },
    });
    sources[0].emit("changed", "lib/config.lua");
    sources[0].emit("reload", "revision-remount");
    await turn();
    await turn();
    assert.equal(remounts, 1);
    assert.equal(reloads, 0);
  } finally {
    globalThis.EventSource = originalEventSource;
    globalThis.fetch = originalFetch;
  }
});
