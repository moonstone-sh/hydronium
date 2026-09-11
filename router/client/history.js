/*
  hydronium_router.client.history -- the browser-side implementation of
  `hydronium_router.history.browser`'s five-function `__router_*` bridge
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

/** @returns {Record<string, Function>} the 5 required bridge functions */
export function createHistoryBridge(win = window) {
  return {
    push_state(url, state) {
      win.history.pushState(state ?? null, "", url);
    },
    replace_state(url, state) {
      win.history.replaceState(state ?? null, "", url);
    },
    go(delta) {
      win.history.go(delta);
    },
    location_href() {
      return win.location.pathname + win.location.search + win.location.hash;
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
