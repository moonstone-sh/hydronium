import test from "node:test";
import assert from "node:assert/strict";

import { installHmr } from "../../dom/src/hydronium_dom/client/hmr.js";

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
