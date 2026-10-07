/*
  hydronium.client.canvas_bridge -- the `canvas@1` host capability: the parts
  of the Canvas API that Lua cannot reach through host references.

  Elements and contexts already cross into Lua as host references, so
  `canvas:getContext("2d")`, `ctx:fillRect(...)` and `ctx.fillStyle = "red"`
  need nothing here. What does: constructors (a host reference cannot `new`),
  frame loops that call back into Lua, image loading, device pixel ratio and
  resize observation. hydronium_dom.canvas wraps these for components
  (scope cleanup, server no-ops); see dom/types/dom/canvas.d.lua for types.

  Lua functions arrive as engine callbacks: a plain function (Wasmoon) or a
  handle with `.call([args])` and `.release()` (lua-wasm). `invoke` handles
  both, as dom_bridge's listeners do.
*/

const invoke = (fn, args) => (typeof fn === "function" ? fn(...args) : fn.call(args));
const release = (fn) => fn?.release?.();

function requireGlobal(name) {
  const value = globalThis[name];
  if (typeof value !== "function") throw new Error(`canvas: ${name} is not available in this environment`);
  return value;
}

/** @returns {Record<string, Function>} */
export function createCanvasBridge() {
  return {
    /** new Path2D(svgPathData?) or a copy of another Path2D. */
    path(init) {
      const Path2D = requireGlobal("Path2D");
      return init == null ? new Path2D() : new Path2D(init);
    },

    /** new ImageData(width, height) */
    image_data(width, height) {
      return new (requireGlobal("ImageData"))(width, height);
    },

    /**
     * new ImageData from RGBA bytes: a Lua array of 0..255 values (or any
     * array-like) and its width; height follows from the length.
     */
    image_data_from(bytes, width, height) {
      const ImageData = requireGlobal("ImageData");
      const data = bytes instanceof Uint8ClampedArray ? bytes : Uint8ClampedArray.from(bytes);
      return height == null ? new ImageData(data, width) : new ImageData(data, width, height);
    },

    /** new DOMMatrix(init?): a CSS transform string or a 6/16-number array. */
    matrix(init) {
      const DOMMatrix = requireGlobal("DOMMatrix");
      return init == null ? new DOMMatrix() : new DOMMatrix(init);
    },

    /** new OffscreenCanvas(width, height) */
    offscreen(width, height) {
      return new (requireGlobal("OffscreenCanvas"))(width, height);
    },

    /** Resolves with a decoded HTMLImageElement (Lua suspends until then). */
    async load_image(src, crossOrigin) {
      const image = new (requireGlobal("Image"))();
      if (crossOrigin != null) image.crossOrigin = crossOrigin;
      image.src = src;
      await image.decode();
      return image;
    },

    /** createImageBitmap(source, ...): resolves with an ImageBitmap. */
    bitmap(source, ...rest) {
      return requireGlobal("createImageBitmap")(source, ...rest);
    },

    /** window.devicePixelRatio (1 where there is none). */
    device_pixel_ratio() {
      return globalThis.devicePixelRatio || 1;
    },

    /**
     * Calls `callback(timestampMs, deltaMs)` every animation frame until it
     * returns false or the returned stop function is called. One frame's
     * callback finishes before the next is scheduled, so a slow Lua frame
     * never queues up behind itself.
     */
    frame_loop(callback) {
      const raf = requireGlobal("requestAnimationFrame");
      const caf = requireGlobal("cancelAnimationFrame");
      let id = 0;
      let stopped = false;
      let last;
      const stop = () => {
        if (stopped) return;
        stopped = true;
        if (id) caf(id);
        release(callback);
      };
      const frame = async (time) => {
        id = 0;
        if (stopped) return;
        const delta = last == null ? 0 : time - last;
        last = time;
        let result;
        try {
          result = await invoke(callback, [time, delta]);
        } catch (error) {
          stop();
          throw error;
        }
        if (Array.isArray(result)) result = result[0];
        if (result === false) stop();
        else if (!stopped) id = raf(frame);
      };
      id = raf(frame);
      return stop;
    },

    /**
     * Calls `callback(widthCss, heightCss)` when the element's box changes
     * (and once at start). Returns a function that stops observing.
     */
    observe_resize(element, callback) {
      const ResizeObserver = requireGlobal("ResizeObserver");
      const observer = new ResizeObserver((entries) => {
        const box = entries[entries.length - 1]?.contentRect;
        if (box) invoke(callback, [box.width, box.height]);
      });
      observer.observe(element);
      let stopped = false;
      return () => {
        if (stopped) return;
        stopped = true;
        observer.disconnect();
        release(callback);
      };
    },
  };
}
