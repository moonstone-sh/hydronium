/*
  hydronium_router.client.history -- the browser-side implementation of
  `hydronium_router.history.browser`'s six-function `__router_*` bridge
  contract (see that module's own doc comment for the contract).

  Same shape as `hydronium-dom`'s `createDomBridge()`: a factory
  returning a plain object whose keys are exactly the bridge function
  names the Lua side expects, so it can be handed to wasmoon per-key:

    const bridge = createHistoryBridge();
    for (const [name, fn] of Object.entries(bridge)) {
      lua.global.set("__router_" + name, fn);
    }
    // then, in Lua:
    //   require("hydronium_router.history.browser").create_browser_history()
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
      const handler = () => fn();
      win.addEventListener("popstate", handler);
      return () => win.removeEventListener("popstate", handler);
    },
  };
}

/**
 * Produces the exact object accepted by hydronium-dom mount's `luaGlobals`.
 * Keeping prefixing here prevents every application from reimplementing the
 * JS-to-Lua bridge naming contract.
 */
export function createHistoryGlobals(win = window) {
  return Object.fromEntries(
    Object.entries(createHistoryBridge(win)).map(([name, fn]) => [`__router_${name}`, fn])
  );
}
