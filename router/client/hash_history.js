/*
  hydronium_router.client.hash_history -- the browser-side implementation of
  `hydronium_router.history.hash`'s five-function bridge contract (see
  that module's own doc comment), provided as the `router.hash_history@1`
  host capability:

    mount({ ..., hostCapabilities: [createHashHistoryCapability()] });
    // then, in Lua:
    //   require("hydronium_router.history.hash").create_hash_history()

  `createHashHistoryBridge()` returns the bare bindings, like
  ./history.js's `createHistoryBridge()`. The `__router_hash_*` globals of
  earlier releases were removed.

  UNLIKE pushState, assigning `location.hash` fires a real "hashchange"
  event for the navigation it just caused (queued as a task, not
  synchronous) -- `history.js`'s bridge needs a self-vs-external counter
  for exactly the opposite reason (pushState never echoes). This bridge's
  Lua-side counterpart instead recognizes its own echo by comparing the
  fired hash against the last one it wrote; see hash.lua's own doc
  comment for the full reasoning.
*/

const STATE_KEY = "__hydronium_router_hash_state_v1";

function stateEnvelope(serialized) {
  if (typeof serialized !== "string") {
    throw new TypeError("hydronium-router hash history state must cross the bridge as serialized text");
  }
  return { [STATE_KEY]: serialized };
}

/** @returns {Record<string, Function>} the 5 required bridge functions */
export function createHashHistoryBridge(win = window) {
  return {
    read() {
      return win.location.hash;
    },
    // Assigning `location.hash` is the one plain-navigation API that adds
    // a real session-history entry without `pushState` -- exactly what
    // `hash.lua`'s `push` needs the physical back button to later see.
    // The `replaceState` call right after attaches the caller's state to
    // that SAME entry (it does not add a second one), since
    // `location.hash = href` alone has no way to carry a state payload.
    write(href, stateJson) {
      win.location.hash = href;
      win.history.replaceState(stateEnvelope(stateJson), "", win.location.href);
    },
    replace(href, stateJson) {
      const url = new URL(win.location.href);
      url.hash = href;
      win.history.replaceState(stateEnvelope(stateJson), "", url);
    },
    go(delta) {
      win.history.go(delta);
    },
    on_change(fn) {
      const handler = () => {
        const result = typeof fn === "function" ? fn() : fn.call([]);
        result?.catch?.((error) => console.error("[hydronium-router] hashchange callback failed:", error));
      };
      win.addEventListener("hashchange", handler);
      return () => { win.removeEventListener("hashchange", handler); fn?.release?.(); };
    },
  };
}

/**
 * The `router.hash_history@1` host capability, for hydronium-dom mount's
 * `hostCapabilities` list. `hydronium_router.history.hash.create()`
 * resolves it from hydronium.runtime.hosts.
 */
export function createHashHistoryCapability(win = window) {
  return { name: "router.hash_history", version: 1, bindings: createHashHistoryBridge(win) };
}
