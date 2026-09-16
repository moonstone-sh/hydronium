import test from "node:test";
import assert from "node:assert/strict";
import { createHistoryBridge, createHistoryGlobals } from "../../router/client/history.js";

function fakeWindow() {
  const listeners = new Map();
  return {
    location: { pathname: "/a:b", search: "?q=x%20y", hash: "#top" },
    history: {
      state: null,
      pushState(state, _title, url) { this.state = state; this.lastPush = { state, url }; },
      replaceState(state, _title, url) { this.state = state; this.lastReplace = { state, url }; },
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
  assert.equal(bridge.location_state(), "null");
  const serialized = '{"nested":{"message":"sad pepe: Olá, 世界 👋"}}';
  bridge.push_state("/stage:dev?name=sad%20pepe", serialized);
  assert.deepEqual(win.history.lastPush, {
    state: { __hydronium_router_state_v1: serialized },
    url: "/stage:dev?name=sad%20pepe",
  });
  assert.equal(bridge.location_state(), serialized);

  bridge.replace_state("/stage:prod", "null");
  assert.equal(bridge.location_state(), "null");

  const globals = createHistoryGlobals(win);
  assert.deepEqual(Object.keys(globals).sort(), [
    "__router_go",
    "__router_location_href",
    "__router_location_state",
    "__router_on_popstate",
    "__router_push_state",
    "__router_replace_state",
  ]);
  assert.equal(globals.__router_location_href(), "/a:b?q=x%20y#top");
});

test("router browser bridge ignores foreign state and rejects opaque objects", () => {
  const win = fakeWindow();
  win.history.state = { fromAnotherRouter: true };
  const bridge = createHistoryBridge(win);
  assert.equal(bridge.location_state(), "null");
  assert.throws(() => bridge.push_state("/bad", { direct: "object" }), /serialized text/);
});
