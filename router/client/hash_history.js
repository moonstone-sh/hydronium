/*
  hydronium_router.client.hash_history -- the browser-side implementation of
  `hydronium_router.history.hash`'s five-function `__router_hash_*` bridge
  contract (see that module's own doc comment for the contract).

  Same shape as ./history.js's `createHistoryBridge()` (which backs the
  pushState-based `hydronium_router.history.browser`'s `__router_*`
  bridge): a factory returning a plain object whose keys are exactly the
  bridge function names the Lua side expects, so it can be handed to
  wasmoon per-key:

    const bridge = createHashHistoryBridge();
    for (const [name, fn] of Object.entries(bridge)) {
      lua.global.set("__router_hash_" + name, fn);
    }
    // then, in Lua:
    //   require("hydronium_router.history.hash").create_hash_history()

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
      const handler = () => fn();
      win.addEventListener("hashchange", handler);
      return () => win.removeEventListener("hashchange", handler);
    },
  };
}

/**
 * Produces the exact object accepted by hydronium-dom mount's `luaGlobals`.
 * Keeping prefixing here prevents every application from reimplementing the
 * JS-to-Lua bridge naming contract.
 */
export function createHashHistoryGlobals(win = window) {
  return Object.fromEntries(
    Object.entries(createHashHistoryBridge(win)).map(([name, fn]) => [`__router_hash_${name}`, fn])
  );
}
