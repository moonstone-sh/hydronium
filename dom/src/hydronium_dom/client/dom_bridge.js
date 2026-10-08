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
  expects (`create_element`, `create_text`, ...). `mount()` installs
  these through the selected Lua engine provider:

    const bridge = createDomBridge();
    for (const [name, fn] of Object.entries(bridge)) {
      lua.global.set("__dom_" + name, fn);
    }
    // Compatibility embedding only. mount() now uses installHostCapability
    // to register dom@1 in hydronium.runtime.hosts, then injects that table.
    // then, in Lua: require("hydronium.host.dom").createDomHost()
    //   (no-arg form reads the __dom_* globals just set above)

  For legacy embeddings, `hydronium.host.dom.createDomHost` still accepts
  an explicit bridge table or the `__dom_*` globals.
*/

/** @returns {Record<string, Function>} the 15 required bridge functions, plus the 1 optional one (hydration_mismatch) */
let currentEvent;
const CURRENT_EVENT = Symbol.for("hydronium.dom.currentEvent");
const EVENT_PAYLOADS = Symbol.for("hydronium.dom.eventPayloads");

// The event a Lua handler receives: a snapshot taken during dispatch, while
// currentTarget is still live, of the fields the synthetic event types in
// dom/types/dom/events.d.lua declare. Primitive fields are copied, so the
// handler reads what was true when the event fired; target/currentTarget stay
// live element references. preventDefault/stopPropagation only take effect
// while the browser is still dispatching (a synchronous engine).
const EVENT_FIELDS = ["data", "inputType", "key", "code", "repeat", "altKey", "ctrlKey", "metaKey", "shiftKey",
  "clientX", "clientY", "screenX", "screenY", "pageX", "pageY", "button", "buttons", "deltaX", "deltaY", "deltaZ", "deltaMode"];
const FORM_CONTROLS = new Set(["INPUT", "TEXTAREA", "SELECT"]);

export function snapshotDomEvent(event) {
  const target = event.target;
  const snapshot = {
    type: event.type,
    timeStamp: event.timeStamp,
    target,
    currentTarget: event.currentTarget,
    preventDefault: () => event.preventDefault(),
    stopPropagation: () => event.stopPropagation(),
    isDefaultPrevented: () => event.defaultPrevented,
    isPropagationStopped: () => false,
  };
  for (const field of EVENT_FIELDS) {
    if (event[field] !== undefined) snapshot[field] = event[field];
  }
  // Form controls: what onInput/onChange handlers almost always need.
  if (target && typeof target.value === "string") snapshot.value = target.value;
  if (target && typeof target.checked === "boolean") snapshot.checked = target.checked;
  if (target && typeof target.name === "string" && target.name) snapshot.name = target.name;
  return snapshot;
}

export function getCurrentDomEvent() {
  return currentEvent ?? globalThis[CURRENT_EVENT];
}

export function shouldHandleNavigation(event) {
  if (!event || event.defaultPrevented) return false;
  if (event.button != null && event.button !== 0) return false;
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return false;
  const anchor = event.currentTarget;
  if (!anchor) return false;
  if (anchor.hasAttribute?.("download")) return false;
  const target = anchor.getAttribute?.("target");
  if (target && target.toLowerCase() !== "_self") return false;
  const href = anchor.getAttribute?.("href");
  if (!href) return false;
  try {
    const url = new URL(href, globalThis.location?.href);
    if (globalThis.location && url.origin !== globalThis.location.origin) return false;
  } catch {
    return false;
  }
  return true;
}

export function createDomBridge() {
  /** @type {WeakMap<Node, Map<string, EventListener>>} */
  const listenerMap = new WeakMap();

  function tagOf(node) {
    return node && node.nodeType === 1 ? node.tagName.toLowerCase() : undefined;
  }

  return {
    observe_virtual_item(el, axis, onMeasure) {
      const horizontal = axis === "horizontal";
      const report = () => {
        const value = horizontal ? el.getBoundingClientRect().width : el.getBoundingClientRect().height;
        const result = typeof onMeasure === "function" ? onMeasure(value) : onMeasure.call([value]);
        result?.catch?.((error) => console.error("[hydronium] virtual item callback failed:", error));
      };
      const observer = typeof ResizeObserver === "function" ? new ResizeObserver(report) : null;
      observer?.observe(el); report();
      return () => { observer?.disconnect(); onMeasure?.release?.(); };
    },
    observe_virtual_container(el, axis, onViewport, onOffset) {
      const horizontal = axis === "horizontal";
      const invoke = (callback, value) => {
        const result = typeof callback === "function" ? callback(value) : callback.call([value]);
        result?.catch?.((error) => console.error("[hydronium] virtual container callback failed:", error));
      };
      const sync = () => { invoke(onViewport, horizontal ? el.clientWidth : el.clientHeight); invoke(onOffset, horizontal ? el.scrollLeft : el.scrollTop); };
      el.addEventListener("scroll", sync, { passive: true });
      const observer = typeof ResizeObserver === "function" ? new ResizeObserver(sync) : null;
      observer?.observe(el); sync();
      return () => { el.removeEventListener("scroll", sync); observer?.disconnect(); onViewport?.release?.(); onOffset?.release?.(); };
    },
    scroll_virtual_container(el, axis, offset) { el[axis === "horizontal" ? "scrollLeft" : "scrollTop"] = offset; },
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
      if (key === "unsafe_raw_html" || key === "dangerouslySetInnerHTML") {
        el.innerHTML = String(key === "dangerouslySetInnerHTML" ? value?.__html ?? "" : value);
        return;
      }
      if (key === "id") { el.id = String(value); return; }
      // Live form state is a property, not the attribute: after the user
      // types, the value attribute no longer changes what the control shows.
      if (key === "value" && FORM_CONTROLS.has(el.tagName)) {
        const text = String(value);
        if (el.value !== text) el.value = text;
        el.setAttribute(key, text);
        return;
      }
      if ((key === "checked" || key === "selected") && key in el) {
        el[key] = Boolean(value);
        if (value) el.setAttribute(key, "");
        else el.removeAttribute(key);
        return;
      }
      if (typeof value === "boolean") {
        if (value) el.setAttribute(key, "");
        else el.removeAttribute(key);
        return;
      }
      el.setAttribute(key, String(value));
    },
    remove_attr(el, key) {
      if (key === "unsafe_raw_html" || key === "dangerouslySetInnerHTML") {
        el.innerHTML = "";
        return;
      }
      if (key === "id") { el.id = ""; return; }
      if (key === "value" && FORM_CONTROLS.has(el.tagName)) el.value = "";
      if ((key === "checked" || key === "selected") && key in el) el[key] = false;
      el.removeAttribute(key);
    },
    // Optional (hydronium.host.dom.createDomHost does not require these
    // two to be present) -- per-property access to the element's inline
    // style, which is what lets a re-render add, change or remove ONE
    // declaration without rewriting the whole `style` attribute and
    // clobbering declarations another code path set. When a bridge omits
    // them, hydronium.host.dom falls back to regenerating the attribute
    // wholesale, which is correct but not surgical.
    //
    // Property names arrive already normalized to kebab-case by
    // hydronium_dom.style (the same normalization SSR uses), which is
    // exactly what CSSStyleDeclaration.setProperty takes natively -- so
    // no camelCase bridging is needed or wanted here.
    set_style_property(el, name, value) {
      el.style.setProperty(name, String(value));
    },
    remove_style_property(el, name) {
      el.style.removeProperty(name);
    },
    // REPLACES any previously-registered listener for this event name on
    // this element -- required by hydronium.host.dom's own contract (see
    // its doc comment on `set_listener`): this is what lets ordinary
    // reconciliation replace a component's onClick body across an HMR
    // refresh, with no HMR-specific code anywhere in this file.
    set_listener(el, eventName, fn) {
      const domEventName = eventName === "navigate" ? "click" : eventName;
      let m = listenerMap.get(el);
      if (!m) { m = new Map(); listenerMap.set(el, m); }
      const prev = m.get(eventName);
      if (prev) { el.removeEventListener(domEventName, prev); prev.luaCallback?.release?.(); }
      // Browser Event objects are not passed directly as Lua callback
      // arguments. Callbacks stay argument-free unless an event adapter has
      // captured a transport-safe payload such as a string.
      const handler = (event) => {
        if (eventName === "navigate" && !shouldHandleNavigation(event)) return;
        // Lua callbacks cross an asynchronous engine boundary, after the
        // browser's cancellation window. Controlled submit and
        // router-navigation events must therefore be cancelled before
        // invoking Lua.
        if (eventName === "submit" || eventName === "navigate") {
          event.preventDefault();
        }
        currentEvent = event;
        globalThis[CURRENT_EVENT] = event;
        const clear = () => {
          if (currentEvent === event) currentEvent = undefined;
          if (globalThis[CURRENT_EVENT] === event) globalThis[CURRENT_EVENT] = undefined;
        };
        try {
          // Some embedders schedule the Lua callback after this listener
          // returns. Snapshot the event while currentTarget is still live.
          // A registered adapter wins (forms.js turns submit into a values
          // literal). submit and navigate otherwise stay argument-free, as
          // hydronium.forms expects; every other event gets a snapshot.
          const payloadFactory = globalThis[EVENT_PAYLOADS]?.get?.(eventName);
          const payload = payloadFactory
            ? payloadFactory(event)
            : eventName === "submit" || eventName === "navigate" ? undefined : snapshotDomEvent(event);
          const result = typeof fn === "function"
            ? (payload === undefined ? fn() : fn(payload))
            : fn.call(payload === undefined ? [] : [payload]);
          // Engine callbacks may be promise-backed even when the Lua
          // function itself is synchronous. Keep the event current until Lua
          // has finished calling bridge atoms such as form_values().
          if (result && typeof result.then === "function") {
            result.finally(clear);
          } else {
            clear();
          }
        } catch (error) {
          clear();
          throw error;
        }
      };
      handler.luaCallback = fn;
      m.set(eventName, handler);
      el.addEventListener(domEventName, handler);
    },
    prevent_default() {
      currentEvent?.preventDefault?.();
    },
    remove_listener(el, eventName) {
      const m = listenerMap.get(el);
      if (!m) return;
      const prev = m.get(eventName);
      if (prev) {
        el.removeEventListener(eventName === "navigate" ? "click" : eventName, prev);
        prev.luaCallback?.release?.();
        m.delete(eventName);
      }
    },
    // Hydration helpers. IMPORTANT (found the hard way, verified live via
    // Playwright, documented in docs/HMR_DOM_HOST.md Part IV): these
    // return `undefined`, never `null`, for "no such node" -- this also
    // preserves compatibility with the original Wasmoon embedding, whose
    // JS<->Lua marshalling mishandled a bare `null` return.
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
