/*
  hydronium.client.dom_bridge -- the real, standalone, reusable
  implementation of `hydronium.host.dom`'s documented `__dom_*` bridge
  contract (see src/hydronium/host/dom.lua's own doc comment for the
  full fifteen-function contract this satisfies).

  Extracted from what was, until this module existed, a hand-typed copy
  living inline inside a single verification page
  (examples/meteorite_ssr/hmr_demo/dom_host_proof.html) -- real and
  correct, but not something any real app could import, and a second
  hand-typed copy of the same logic every consumer would have had to
  re-derive. This is that logic, once, as an actual module.

  Usage: `createDomBridge()` returns a plain object whose keys are
  exactly the bridge function names `hydronium.host.dom.createDomHost`
  expects (`create_element`, `create_text`, ...) -- pass it straight to
  wasmoon:

    const bridge = createDomBridge();
    for (const [name, fn] of Object.entries(bridge)) {
      lua.global.set("__dom_" + name, fn);
    }
    // then, in Lua: require("hydronium.host.dom").createDomHost()
    //   (no-arg form reads the __dom_* globals just set above)

  or, since `hydronium.host.dom.createDomHost` also accepts an explicit
  bridge table directly (no globals involved), pass `bridge` itself into
  Lua as a table if your embedding supports marshalling a JS object into
  a Lua table with callable function values (wasmoon does, via
  `lua.global.set` per-key as shown above -- there is no single-call
  "set a whole nested table of functions" in wasmoon's API, hence the
  per-key loop).
*/

/** @returns {Record<string, Function>} the 15 required bridge functions, plus the 1 optional one (hydration_mismatch) */
export function createDomBridge() {
  /** @type {WeakMap<Node, Map<string, EventListener>>} */
  const listenerMap = new WeakMap();

  function tagOf(node) {
    return node && node.nodeType === 1 ? node.tagName.toLowerCase() : undefined;
  }

  return {
    create_element(tag) {
      return document.createElement(tag);
    },
    create_text(text) {
      return document.createTextNode(text);
    },
    set_text(node, text) {
      node.textContent = text;
    },
    append_child(parent, child) {
      parent.appendChild(child);
    },
    insert_before(parent, child, before) {
      parent.insertBefore(child, before);
    },
    remove_child(parent, child) {
      if (child.parentNode === parent) parent.removeChild(child);
    },
    set_attr(el, key, value) {
      if (key === "id") { el.id = String(value); return; }
      if (typeof value === "boolean") {
        if (value) el.setAttribute(key, "");
        else el.removeAttribute(key);
        return;
      }
      el.setAttribute(key, String(value));
    },
    remove_attr(el, key) {
      if (key === "id") { el.id = ""; return; }
      el.removeAttribute(key);
    },
    // REPLACES any previously-registered listener for this event name on
    // this element -- required by hydronium.host.dom's own contract (see
    // its doc comment on `set_listener`): this is what lets ordinary
    // reconciliation replace a component's onClick body across an HMR
    // refresh, with no HMR-specific code anywhere in this file.
    set_listener(el, eventName, fn) {
      let m = listenerMap.get(el);
      if (!m) { m = new Map(); listenerMap.set(el, m); }
      const prev = m.get(eventName);
      if (prev) el.removeEventListener(eventName, prev);
      const handler = () => fn();
      m.set(eventName, handler);
      el.addEventListener(eventName, handler);
    },
    remove_listener(el, eventName) {
      const m = listenerMap.get(el);
      if (!m) return;
      const prev = m.get(eventName);
      if (prev) { el.removeEventListener(eventName, prev); m.delete(eventName); }
    },
    // Hydration helpers. IMPORTANT (found the hard way, verified live via
    // Playwright, documented in docs/HMR_DOM_HOST.md Part IV): these
    // return `undefined`, never `null`, for "no such node" -- wasmoon's
    // JS<->Lua value marshalling mishandles a bare `null` return from a
    // bridged function in a way `undefined` does not (a real bug hit
    // while building the original proof this module was extracted from).
    first_child(node) {
      return node.firstChild || undefined;
    },
    next_sibling(node) {
      return node.nextSibling || undefined;
    },
    is_element(node) {
      return node != null && node.nodeType === 1;
    },
    is_text(node) {
      return node != null && node.nodeType === 3;
    },
    tag_of(node) {
      return tagOf(node);
    },
    // Optional (hydronium.host.dom.createDomHost does not require this
    // one to be present) -- lets Reconciler:hydrate's transparent-island
    // branch skip real SSR-emitted HTML comment island markers
    // (<!--hy:i:...-->/<!--hy:/i:...-->) instead of misreading one as a
    // real content mismatch. Found live, via a real SSR-to-hydrate
    // Playwright proof, that without this hydration silently fell back
    // to a full remount for every real island-wrapped page (i.e. every
    // real page using d.lua.mount, the only documented root-mount API) --
    // see core/reconciler.lua's own doc comment on that branch.
    is_comment(node) {
      return node != null && node.nodeType === 8;
    },
    // Optional (hydronium.host.dom.createDomHost does not require this
    // one to be present) -- surfaces a real hydration mismatch to the
    // browser console instead of only an in-VM Lua table nothing else
    // reads.
    hydration_mismatch(reason) {
      console.warn("[hydronium] hydration mismatch:", reason);
    },
  };
}
