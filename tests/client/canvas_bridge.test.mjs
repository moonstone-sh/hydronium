// canvas_bridge.js: the canvas@1 host capability (constructors, frame loops,
// image loading, resize observation), against stand-in browser globals.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createCanvasBridge } from "../../js/packages/dom-client/src/canvas_bridge.js";

function withGlobals(globals, fn) {
  const saved = {};
  for (const [k, v] of Object.entries(globals)) { saved[k] = globalThis[k]; globalThis[k] = v; }
  return Promise.resolve(fn()).finally(() => { for (const k of Object.keys(globals)) globalThis[k] = saved[k]; });
}

function frames() {
  const queue = new Map();
  let next = 1;
  return {
    requestAnimationFrame: (cb) => { const id = next++; queue.set(id, cb); return id; },
    cancelAnimationFrame: (id) => queue.delete(id),
    async tick(time) {
      const due = [...queue.entries()];
      queue.clear();
      for (const [, cb] of due) await cb(time);
    },
    pending: () => queue.size,
  };
}

test("frame_loop passes time and delta, and stops when the callback returns false", async () => {
  const f = frames();
  await withGlobals({ requestAnimationFrame: f.requestAnimationFrame, cancelAnimationFrame: f.cancelAnimationFrame }, async () => {
    const calls = [];
    let released = 0;
    const cb = Object.assign((t, d) => { calls.push([t, d]); return calls.length < 3 ? undefined : false; }, { release: () => released++ });
    createCanvasBridge().frame_loop(cb);
    await f.tick(100); await f.tick(116); await f.tick(133);
    assert.deepEqual(calls, [[100, 0], [116, 16], [133, 17]]);
    assert.equal(f.pending(), 0, "no frame scheduled after false");
    assert.equal(released, 1, "the Lua callback is released once");
  });
});

test("frame_loop's stop cancels the pending frame and releases the callback", async () => {
  const f = frames();
  await withGlobals({ requestAnimationFrame: f.requestAnimationFrame, cancelAnimationFrame: f.cancelAnimationFrame }, async () => {
    let released = 0, runs = 0;
    // A lua-wasm style handle: .call(args) returns a promise of the results.
    const handle = { call: async () => { runs++; return [undefined]; }, release: () => released++ };
    const stop = createCanvasBridge().frame_loop(handle);
    await f.tick(10);
    assert.equal(runs, 1);
    stop(); stop();
    assert.equal(f.pending(), 0);
    assert.equal(released, 1);
  });
});

test("constructors build the browser objects; image_data_from takes a Lua byte array", async () => {
  class Path2D { constructor(d) { this.d = d; } }
  class ImageData { constructor(a, b, c) { this.args = [a, b, c]; } }
  class DOMMatrix { constructor(init) { this.init = init; } }
  class OffscreenCanvas { constructor(w, h) { this.size = [w, h]; } }
  await withGlobals({ Path2D, ImageData, DOMMatrix, OffscreenCanvas }, () => {
    const b = createCanvasBridge();
    assert.equal(b.path("M0 0").d, "M0 0");
    assert.equal(b.path().d, undefined);
    assert.deepEqual(b.image_data(2, 3).args, [2, 3, undefined]);
    const px = b.image_data_from([255, 0, 0, 255], 1);
    assert.ok(px.args[0] instanceof Uint8ClampedArray);
    assert.deepEqual([...px.args[0]], [255, 0, 0, 255]);
    assert.equal(b.matrix([1, 0, 0, 1, 5, 5]).init.length, 6);
    assert.deepEqual(b.offscreen(8, 4).size, [8, 4]);
  });
});

test("missing browser APIs fail with a clear message", () => {
  assert.throws(() => createCanvasBridge().offscreen(1, 1), /OffscreenCanvas is not available/);
});

test("observe_resize reports CSS size and its disposer disconnects once", async () => {
  let observer;
  class ResizeObserver {
    constructor(cb) { this.cb = cb; this.disconnects = 0; observer = this; }
    observe(el) { this.el = el; }
    disconnect() { this.disconnects++; }
  }
  await withGlobals({ ResizeObserver }, () => {
    const sizes = [];
    let released = 0;
    const stop = createCanvasBridge().observe_resize("el", Object.assign((w, h) => sizes.push([w, h]), { release: () => released++ }));
    observer.cb([{ contentRect: { width: 300, height: 150 } }]);
    assert.deepEqual(sizes, [[300, 150]]);
    stop(); stop();
    assert.equal(observer.disconnects, 1);
    assert.equal(released, 1);
  });
});
