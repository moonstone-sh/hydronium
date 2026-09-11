import test from "node:test";
import assert from "node:assert/strict";
import { createHistoryBridge, createHistoryGlobals } from "../../router/client/history.js";

function fakeWindow() {
  const listeners = new Map();
  return {
    location: { pathname: "/a:b", search: "?q=x%20y", hash: "#top" },
    history: {
      pushState(state, _title, url) { this.lastPush = { state, url }; },
      replaceState(state, _title, url) { this.lastReplace = { state, url }; },
      go(delta) { this.lastDelta = delta; },
    },
    addEventListener(name, fn) { listeners.set(name, fn); },
    removeEventListener(name, fn) { if (listeners.get(name) === fn) listeners.delete(name); },
    listeners,
  };
}

test("router browser bridge preserves URL punctuation and exposes prefixed Lua globals", () => {
  const win = fakeWindow();
  const bridge = createHistoryBridge(win);
  assert.equal(bridge.location_href(), "/a:b?q=x%20y#top");
  bridge.push_state("/stage:dev?name=sad%20pepe", { ok: true });
  assert.deepEqual(win.history.lastPush, { state: { ok: true }, url: "/stage:dev?name=sad%20pepe" });

  const globals = createHistoryGlobals(win);
  assert.deepEqual(Object.keys(globals).sort(), [
    "__router_go",
    "__router_location_href",
    "__router_on_popstate",
    "__router_push_state",
    "__router_replace_state",
  ]);
  assert.equal(globals.__router_location_href(), "/a:b?q=x%20y#top");
});
