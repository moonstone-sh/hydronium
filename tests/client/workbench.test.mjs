import test from "node:test";
import {patchXtermCoordinates} from "../../ink-lab/scripts/xterm-transform.mjs";
import assert from "node:assert/strict";

import {
  snapViewportPan, rulerStep,
  GRID_DEFAULTS,
  gridPattern,
  installWorkbenchPreferences,
  normalizeGridPreferences,
} from "../../lab/src/hydronium_lab/client/workbench.js";

test("Workbench grid preferences normalize unsafe persisted values", () => {
  assert.deepEqual(normalizeGridPreferences({
    enabled: false,
    color: "#ABCDEF",
    width: 2,
    height: 999,
    shape: "hexagonal",
  }), {
    enabled: false,
    color: "#abcdef",
    width: 8,
    height: 160,
    shape: "hexagonal",
  });
  assert.deepEqual(normalizeGridPreferences({ color: "red", shape: "triangles" }), GRID_DEFAULTS);
});

test("Workbench creates square and real hexagonal grid patterns", () => {
  const square = gridPattern({ width: 20, height: 30, color: "#123456" });
  assert.match(square.image, /linear-gradient/);
  assert.equal(square.size, "20px 30px");

  const hexagonal = gridPattern({ shape: "hexagonal", width: 20, height: 30, color: "#123456" });
  assert.match(hexagonal.image, /^url\("data:image\/svg\+xml,/);
  assert.match(decodeURIComponent(hexagonal.image), /<polygon/);
  assert.equal(hexagonal.size, "30px 30px");
});

test("Workbench applies, persists, and independently resets grid settings", () => {
  class Control {
    constructor(dataset = {}) {
      this.dataset = dataset;
      this.style = {};
      this.listeners = new Map();
      this.value = "";
      this.checked = false;
    }
    addEventListener(name, handler) { this.listeners.set(name, handler); }
    removeEventListener(name) { this.listeners.delete(name); }
    emit(name) { this.listeners.get(name)?.({ target: this }); }
  }

  const roles = Object.fromEntries([
    "grid", "grid-enabled", "grid-color", "grid-width", "grid-height", "grid-shape",
  ].map((role) => [role, new Control()]));
  const resets = Object.keys(GRID_DEFAULTS).map((key) => new Control({ labGridReset: key }));
  const root = {
    querySelector(selector) {
      const match = selector.match(/^\[data-lab-(.+)\]$/);
      return match ? roles[match[1]] : null;
    },
    querySelectorAll(selector) { return selector === "[data-lab-grid-reset]" ? resets : []; },
  };
  const preferences = { theme: "midnight", grid: { enabled: false, width: 32, height: 18, shape: "hexagonal" } };
  const patches = [];
  const controller = installWorkbenchPreferences({ root, preferences, persist: (patch) => patches.push(patch) });

  assert.equal(roles.grid.dataset.gridEnabled, "false");
  assert.equal(roles.grid.dataset.gridShape, "hexagonal");
  assert.equal(roles["grid-width"].value, "32");
  assert.equal(preferences.theme, "midnight");

  roles["grid-width"].value = "80";
  roles["grid-width"].emit("change");
  assert.equal(controller.grid.width, 80);
  assert.equal(patches.at(-1).grid.width, 80);

  resets.find((button) => button.dataset.labGridReset === "width").emit("click");
  assert.equal(controller.grid.width, GRID_DEFAULTS.width);
  assert.equal(controller.grid.height, 18);
  assert.equal(preferences.theme, "midnight");

  controller.destroy();
  assert.equal(roles["grid-width"].listeners.size, 0);
});


test('viewport magnets acquire, hold and release in screen pixels and allow Alt bypass',()=>{
  const size={width:800,height:600,stageWidth:1200,stageHeight:900};
  assert.deepEqual(snapViewportPan({x:7,y:-5},size),{x:0,y:0,guides:{x:'center',y:'center'}});
  assert.equal(snapViewportPan({x:12,y:30},size,{x:'center'}).x,0);
  assert.equal(snapViewportPan({x:15,y:30},size,{x:'center'}).x,15);
  assert.equal(snapViewportPan({x:-155,y:30},size).x,-160);
  assert.deepEqual(snapViewportPan({x:3,y:4},size,{},true),{x:3,y:4,guides:{}});
  assert.equal(snapViewportPan({x:7,y:30},{...size,width:1600}).x,0,'center radius is independent of zoom');
});
test('rulers choose readable integer intervals at pixel and cell zooms',()=>{
  assert.equal(rulerStep(1),100);assert.equal(rulerStep(.1),10);assert.equal(rulerStep(.01),1);
  assert.equal(rulerStep(2),200);assert.equal(rulerStep(0),1);
});


test('xterm pointer conversion remains in cell coordinates through ancestor scale and pan',()=>{
  const source='return function(s,t,e){let i=e.getBoundingClientRect(),r=s.getComputedStyle(e),n=parseInt(r.getPropertyValue("padding-left")),o=parseInt(r.getPropertyValue("padding-top"));return[t.clientX-i.left-n,t.clientY-i.top-o]}';
  const coords=new Function(patchXtermCoordinates(source))();
  for(const scale of [.5,1,1.25,2]) {
    const element={offsetWidth:800,offsetHeight:600,getBoundingClientRect:()=>({left:173,top:91,width:800*scale,height:600*scale})};
    const window={getComputedStyle:()=>({getPropertyValue:key=>key==='padding-left'?'4':'6'})};
    assert.deepEqual(coords(window,{clientX:173+84*scale,clientY:91+106*scale},element),[80,100]);
  }
  assert.throws(()=>patchXtermCoordinates('different upstream implementation'),/requires review/);
});


test('snapping can use placed guides independently and obey a configurable distance',()=>{
  const size={width:800,height:600,stageWidth:1200,stageHeight:900,guideTargets:{x:{'guide:custom:start':120}},config:{center:false,edges:false,guides:true,distance:4}};
  assert.deepEqual(snapViewportPan({x:117,y:3},size),{x:120,y:3,guides:{x:'guide:custom:start'}});
  assert.equal(snapViewportPan({x:114,y:3},size).x,114);
  assert.equal(snapViewportPan({x:117,y:3},{...size,config:{...size.config,guides:false}}).x,117);
  assert.equal(snapViewportPan({x:129,y:3},size,{x:'guide:custom:start'}).x,120,'held guide has a wider release distance');
});
