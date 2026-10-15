/*
  hydronium_router.client.history -- the browser-side implementation of
  `hydronium_router.history.browser`'s six-function bridge contract (see
  that module's own doc comment), provided as the `router.history@1` host
  capability:

    mount({ ..., hostCapabilities: [createHistoryCapability()] });
    // then, in Lua:
    //   require("hydronium_router.history.browser").create_browser_history()

  `createHistoryBridge()` returns the bare bindings, for tests or an
  embedding that installs the capability itself. The `__router_*` globals
  of earlier releases were removed.
*/

const STATE_KEY = "__hydronium_router_state_v1";

function stateEnvelope(serialized) {
  if (typeof serialized !== "string") {
    throw new TypeError("hydronium-router history state must cross the bridge as serialized text");
  }
  return { [STATE_KEY]: serialized };
}

function serializedState(state) {
  // Wasmoon's JS-to-Lua promise extension dereferences `.then` on null.
  // The Lua state codec already decodes the JSON text "null" to nil, so
  // always cross this bridge with text, including for fresh/foreign entries.
  if (state === null || typeof state !== "object") return "null";
  return Object.prototype.hasOwnProperty.call(state, STATE_KEY) && typeof state[STATE_KEY] === "string"
    ? state[STATE_KEY]
    : "null";
}

/** @returns {Record<string, Function>} the 6 required bridge functions */
export function createHistoryBridge(win = window) {
  return {
    push_state(url, stateJson) {
      win.history.pushState(stateEnvelope(stateJson), "", url);
    },
    replace_state(url, stateJson) {
      win.history.replaceState(stateEnvelope(stateJson), "", url);
    },
    go(delta) {
      win.history.go(delta);
    },
    location_href() {
      return win.location.pathname + win.location.search + win.location.hash;
    },
    location_state() {
      return serializedState(win.history.state);
    },
    on_popstate(fn) {
      const handler = () => {
        const result = typeof fn === "function" ? fn() : fn.call([]);
        result?.catch?.((error) => console.error("[hydronium-router] popstate callback failed:", error));
      };
      win.addEventListener("popstate", handler);
      return () => { win.removeEventListener("popstate", handler); fn?.release?.(); };
    },
  };
}

/**
 * The `router.history@1` host capability, for hydronium-dom mount's
 * `hostCapabilities` list. `hydronium_router.history.browser.create()`
 * resolves it from hydronium.runtime.hosts.
 */
export function createHistoryCapability(win = window) {
  return { name: "router.history", version: 1, bindings: createHistoryBridge(win) };
}
