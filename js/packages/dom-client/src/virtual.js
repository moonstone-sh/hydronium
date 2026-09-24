// Browser observation adapter for the host-neutral hydronium/virtual state.
export function readScrollOffset(element, axis = "vertical", rtl = false, mode = "default") {
  if (axis === "vertical" || !rtl || mode === "default") return element[axis === "horizontal" ? "scrollLeft" : "scrollTop"];
  const max = element.scrollWidth - element.clientWidth;
  return mode === "negative" ? -element.scrollLeft : max - element.scrollLeft;
}

export function writeScrollOffset(element, axis = "vertical", value, rtl = false, mode = "default") {
  if (axis === "vertical" || !rtl || mode === "default") element[axis === "horizontal" ? "scrollLeft" : "scrollTop"] = value;
  else if (mode === "negative") element.scrollLeft = -value;
  else element.scrollLeft = element.scrollWidth - element.clientWidth - value;
}

// `virtualizer` can be the Lua object when the host bridge exposes methods,
// or callers can supply setters explicitly. rtlMode is injectable because
// browser engines expose three incompatible RTL scrollLeft conventions.
export function bindVirtualizer(element, options = {}) {
  if (!element?.addEventListener) throw new Error("hydronium.virtual: expected a scroll element");
  const virtualizer = options.virtualizer;
  const axis = options.axis ?? virtualizer?.axis?.() ?? "vertical";
  if (axis !== "vertical" && axis !== "horizontal") throw new Error("hydronium.virtual: axis must be vertical or horizontal");
  const rtl = axis === "horizontal" && (options.rtl ?? globalThis.getComputedStyle?.(element).direction === "rtl");
  const mode = options.rtlMode ?? "default";
  const setOffset = options.setScrollOffset ?? ((value) => virtualizer?.setScrollOffset?.(value));
  const setViewport = options.setViewportSize ?? ((value) => virtualizer?.setViewportSize?.(value));
  const sync = () => {
    setOffset(readScrollOffset(element, axis, rtl, mode));
    setViewport(axis === "horizontal" ? element.clientWidth : element.clientHeight);
  };
  element.addEventListener("scroll", sync, { passive: true });
  const observer = typeof ResizeObserver === "function" ? new ResizeObserver(sync) : null;
  observer?.observe(element); sync();
  return { axis, sync, scrollTo(value) { writeScrollOffset(element, axis, value, rtl, mode); sync(); }, dispose() { element.removeEventListener("scroll", sync); observer?.disconnect(); } };
}
