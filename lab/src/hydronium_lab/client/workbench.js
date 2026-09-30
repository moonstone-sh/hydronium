export const GRID_DEFAULTS = Object.freeze({
  enabled: true,
  color: "#6f83ad",
  width: 24,
  height: 24,
  shape: "square",
});

const GRID_MIN = 8;
const GRID_MAX = 160;
const PREFERENCE_DB = "hydronium-lab";
const PREFERENCE_STORE = "projects";

function query(root, role) {
  return root?.querySelector(`[data-lab-${role}]`);
}

function dimension(value, fallback) {
  const parsed = Math.round(Number(value));
  return Number.isFinite(parsed) ? Math.max(GRID_MIN, Math.min(GRID_MAX, parsed)) : fallback;
}

export function normalizeGridPreferences(value = {}) {
  return {
    enabled: typeof value.enabled === "boolean" ? value.enabled : GRID_DEFAULTS.enabled,
    color: typeof value.color === "string" && /^#[0-9a-f]{6}$/i.test(value.color)
      ? value.color.toLowerCase() : GRID_DEFAULTS.color,
    width: dimension(value.width, GRID_DEFAULTS.width),
    height: dimension(value.height, GRID_DEFAULTS.height),
    shape: value.shape === "hexagonal" ? "hexagonal" : GRID_DEFAULTS.shape,
  };
}

export function gridPattern(value) {
  const grid = normalizeGridPreferences(value);
  if (grid.shape === "square") {
    return {
      image: `linear-gradient(${grid.color} 1px, transparent 1px), linear-gradient(90deg, ${grid.color} 1px, transparent 1px)`,
      size: `${grid.width}px ${grid.height}px`,
    };
  }

  // Two staggered pointy-top hexagons form a seamless tile. Because the tile
  // is painted on the world layer (inside the transformed viewport), the
  // strokes scale and translate with the preview rather than the browser.
  const tileWidth = grid.width * 1.5;
  const points = (cx, cy) => [
    [cx - grid.width / 2, cy],
    [cx - grid.width / 4, cy - grid.height / 2],
    [cx + grid.width / 4, cy - grid.height / 2],
    [cx + grid.width / 2, cy],
    [cx + grid.width / 4, cy + grid.height / 2],
    [cx - grid.width / 4, cy + grid.height / 2],
  ].map(([x, y]) => `${x},${y}`).join(" ");
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${tileWidth}" height="${grid.height}" viewBox="0 0 ${tileWidth} ${grid.height}"><g fill="none" stroke="${grid.color}" stroke-width="1"><polygon points="${points(grid.width / 2, grid.height / 2)}"/><polygon points="${points(grid.width * 1.25, 0)}"/><polygon points="${points(grid.width * 1.25, grid.height)}"/></g></svg>`;
  return {
    image: `url("data:image/svg+xml,${encodeURIComponent(svg)}")`,
    size: `${tileWidth}px ${grid.height}px`,
  };
}

function openPreferenceDatabase(name) {
  return new Promise((resolve) => {
    if (typeof indexedDB === "undefined") { resolve(null); return; }
    const open = indexedDB.open(name, 1);
    open.onupgradeneeded = () => {
      if (!open.result.objectStoreNames.contains(PREFERENCE_STORE)) open.result.createObjectStore(PREFERENCE_STORE);
    };
    open.onerror = () => resolve(null);
    open.onsuccess = () => resolve(open.result);
  });
}

async function readPreferences(databaseName, projectKey) {
  const database = await openPreferenceDatabase(databaseName);
  if (!database) return null;
  return new Promise((resolve) => {
    const transaction = database.transaction(PREFERENCE_STORE, "readonly");
    const request = transaction.objectStore(PREFERENCE_STORE).get(projectKey);
    request.onsuccess = () => resolve(request.result || null);
    request.onerror = () => resolve(null);
    transaction.oncomplete = () => database.close();
    transaction.onerror = () => database.close();
  });
}

export async function loadProjectPreferences(projectKey, options = {}) {
  const databaseName = options.databaseName || PREFERENCE_DB;
  const current = await readPreferences(databaseName, projectKey);
  if (current) return current;
  if (!options.legacyDatabaseName || options.legacyDatabaseName === databaseName) return {};
  const legacy = await readPreferences(options.legacyDatabaseName, projectKey);
  if (!legacy) return {};
  saveProjectPreferences(projectKey, legacy, { databaseName });
  return legacy;
}

export async function saveProjectPreferences(projectKey, preferences, options = {}) {
  const database = await openPreferenceDatabase(options.databaseName || PREFERENCE_DB);
  if (!database) return false;
  return new Promise((resolve) => {
    const transaction = database.transaction(PREFERENCE_STORE, "readwrite");
    transaction.objectStore(PREFERENCE_STORE).put(preferences, projectKey);
    transaction.oncomplete = () => { database.close(); resolve(true); };
    transaction.onerror = () => { database.close(); resolve(false); };
  });
}

export function installWorkbenchPreferences({ root, preferences = {}, persist = () => {} }) {
  const layer = query(root, "grid");
  const controls = {
    enabled: query(root, "grid-enabled"),
    color: query(root, "grid-color"),
    width: query(root, "grid-width"),
    height: query(root, "grid-height"),
    shape: query(root, "grid-shape"),
  };
  let grid = normalizeGridPreferences(preferences.grid);
  const listeners = [];

  function listen(target, event, handler) {
    if (!target) return;
    target.addEventListener(event, handler);
    listeners.push(() => target.removeEventListener(event, handler));
  }

  function render() {
    const pattern = gridPattern(grid);
    if (layer) {
      layer.dataset.gridEnabled = String(grid.enabled);
      layer.dataset.gridShape = grid.shape;
      layer.style.backgroundImage = pattern.image;
      layer.style.backgroundSize = pattern.size;
      layer.style.backgroundPosition = "center";
    }
    if (controls.enabled) controls.enabled.checked = grid.enabled;
    if (controls.color) controls.color.value = grid.color;
    if (controls.width) controls.width.value = String(grid.width);
    if (controls.height) controls.height.value = String(grid.height);
    if (controls.shape) controls.shape.value = grid.shape;
  }

  function update(key, value, shouldPersist = true) {
    grid = normalizeGridPreferences({ ...grid, [key]: value });
    preferences.grid = { ...grid };
    render();
    if (shouldPersist) persist({ grid: { ...grid } });
  }

  listen(controls.enabled, "change", () => update("enabled", controls.enabled.checked));
  listen(controls.color, "input", () => update("color", controls.color.value, false));
  listen(controls.color, "change", () => update("color", controls.color.value));
  listen(controls.width, "change", () => update("width", controls.width.value));
  listen(controls.height, "change", () => update("height", controls.height.value));
  listen(controls.shape, "change", () => update("shape", controls.shape.value));
  root?.querySelectorAll("[data-lab-grid-reset]").forEach((button) => {
    const key = button.dataset.labGridReset;
    if (!(key in GRID_DEFAULTS)) return;
    listen(button, "click", () => update(key, GRID_DEFAULTS[key]));
  });

  preferences.grid = { ...grid };
  render();
  return {
    get grid() { return { ...grid }; },
    reset(key) { if (key in GRID_DEFAULTS) update(key, GRID_DEFAULTS[key]); },
    destroy() { listeners.splice(0).forEach((remove) => remove()); },
  };
}

// Observable state shared by the default workbench and custom control outlets.
export function createStoryStore({ send, paint = value => value }) {
  let value = { story: null, args: {}, controls: {}, playback: { nowMs: 0, frame: 0, playing: true, intervalMs: 1000 / 60 } };
  const listeners = new Set();
  const snapshot = () => structuredClone(value);
  const notify = () => { for (const fn of listeners) fn(snapshot()); };
  const accept = frame => { if (frame?.lab) { value = { ...value, args: structuredClone(frame.lab.args), playback: { ...frame.lab.playback } }; notify(); } };
  const operation = async message => { const frame = await send(message); paint(frame); accept(frame); return frame; };
  return {
    getSnapshot: snapshot,
    subscribe(fn) { listeners.add(fn); fn(snapshot()); return () => listeners.delete(fn); },
    select(story) { value = { ...value, story: story.id, controls: story.controls || {}, args: structuredClone(story.args || {}), playback: { ...value.playback, nowMs: 0, frame: 0 } }; notify(); },
    accept,
    setArgs: args => operation({ op: "args", args }),
    resetArgs: () => operation({ op: "resetArgs" }),
    play: () => operation({ op: "playback", playing: true }),
    pause: () => operation({ op: "playback", playing: false }),
    setInterval: intervalMs => operation({ op: "playback", intervalMs }),
    advance: () => operation({ op: "advance" }),
    seek: nowMs => operation({ op: "seek", nowMs }),
    seekFrame: frame => operation({ op: "seekFrame", frame }),
    seekTime: nowMs => operation({ op: "seekTime", nowMs }),
    restart: () => operation({ op: "restart" }),
    destroy() { listeners.clear(); },
  };
}

// Named inputs can appear anywhere in a custom DOM shell. Only explicitly
// marked DefaultControls receive generated fields; outlets keep user markup.
export function bindStoryControls({ root, store, onError = error => {
  const status = root.querySelector("[data-lab-status]");
  if (status) status.textContent = error.message;
} }) {
  const document = root.ownerDocument;
  let story, signature;
  const generated = new Set();
  const optionsFor = control => (control?.options || []).map(option => typeof option === "object" ? option : { label: String(option), value: option });
  const subscribe = store.subscribe(state => {
    const customOutlets = [...root.querySelectorAll("[data-lab-controls-story]")];
    const hasCustom = customOutlets.some(node => node.dataset.labControlsStory === state.story);
    for (const outlet of root.querySelectorAll("[data-lab-controls]")) {
      const storyId = outlet.dataset.labControlsStory;
      outlet.hidden = storyId ? storyId !== state.story : hasCustom;
    }
    const nextSignature = JSON.stringify(state.controls);
    if (story !== state.story || signature !== nextSignature) {
      story = state.story; signature = nextSignature;
      for (const outlet of root.querySelectorAll("[data-lab-default-controls]")) {
        const storyId = outlet.dataset.labControlsStory;
        if (storyId) continue;
        if (!generated.has(outlet) && outlet.childElementCount) continue;
        generated.add(outlet);
        const fields = [];
        for (const [name, control] of Object.entries(state.controls).sort(([a], [b]) => a.localeCompare(b))) {
          const label = document.createElement("label"); label.className = "hydronium-lab__control";
          label.append(document.createTextNode(control.label || name));
          const input = document.createElement(control.type === "select" ? "select" : "input");
          input.dataset.labControl = name;
          input.setAttribute("aria-label", control.label || name);
          if (control.type === "select") {
            for (const [index, option] of optionsFor(control).entries()) {
              const element = document.createElement("option"); element.value = String(index); element.textContent = option.label; input.append(element);
            }
            input.dataset.labOptionIndex = "true";
          } else {
            input.type = control.type === "boolean" ? "checkbox" : control.type === "number" ? "number" : "text";
            for (const key of ["min", "max", "step"]) if (control[key] != null) input.setAttribute(key, control[key]);
          }
          label.append(input); fields.push(label);
        }
        if (fields.length) {
          const reset = document.createElement("button"); reset.type = "button"; reset.dataset.labResetArgs = ""; reset.textContent = "Reset controls"; fields.push(reset);
        }
        outlet.replaceChildren(...fields);
      }
    }
    for (const field of root.querySelectorAll("[data-lab-control]")) {
      const name = field.dataset.labControl, control = state.controls[name], value = state.args[name];
      if (field.type === "checkbox") field.checked = value === true;
      else if (field.dataset.labOptionIndex) field.value = String(optionsFor(control).findIndex(option => option.value === value));
      else if (document.activeElement !== field) field.value = value == null ? "" : String(value);
    }
    for (const button of root.querySelectorAll("[data-lab-play]")) {
      const label = button.querySelector("[data-lab-play-label]");
      if (label) label.textContent = state.playback.playing ? "Pause" : "Play";
      else if (!button.childElementCount) button.textContent = state.playback.playing ? "Pause" : "Play";
      button.setAttribute("aria-label", state.playback.playing ? "Pause playback" : "Play playback");
    }
    for (const field of root.querySelectorAll("[data-lab-frame-interval]")) if (document.activeElement !== field) field.value = String(state.playback.intervalMs);
    for (const field of root.querySelectorAll("[data-lab-frame-position]")) if (document.activeElement !== field) field.value = String(state.playback.frame);
    for (const field of root.querySelectorAll("[data-lab-time-position]")) if (document.activeElement !== field) field.value = String(Number(state.playback.nowMs.toFixed(2)));
    for (const button of root.querySelectorAll("[data-lab-step-back]")) button.disabled = state.playback.frame === 0;
    for (const output of root.querySelectorAll("[data-lab-time]")) output.textContent = `${state.playback.nowMs.toFixed(2)} ms · frame ${state.playback.frame}`;
  });
  const run = promise => promise.catch(onError);
  function edit(event) {
    const field = event.target;
    if (field.matches?.("[data-lab-frame-interval]")) {
      if (event.type === "change" && Number(field.value) > 0) run(store.setInterval(Number(field.value)));
      return;
    }
    if (field.matches?.("[data-lab-frame-position]")) {
      if (event.type === "change" && field.value !== "" && field.checkValidity()) run(store.seekFrame(Number(field.value)));
      return;
    }
    if (field.matches?.("[data-lab-time-position]")) {
      if (event.type === "change" && field.value !== "" && field.checkValidity()) run(store.seekTime(Number(field.value)));
      return;
    }
    if (!field.matches?.("[data-lab-control]")) return;
    const schema = store.getSnapshot().controls[field.dataset.labControl];
    if (!schema) return;
    const discrete = schema.type === "boolean" || schema.type === "select";
    if ((discrete && event.type !== "change") || (!discrete && event.type !== "input")) return;
    let value = field.type === "checkbox" ? field.checked : field.value;
    if (schema.type === "number") { if (field.value === "" || !field.checkValidity()) return; value = Number(value); }
    if (schema.type === "select") {
      const options = optionsFor(schema);
      value = field.dataset.labOptionIndex ? options[Number(value)]?.value : options.find(option => String(option.value) === value)?.value;
      if (value === undefined) return;
    }
    run(store.setArgs({ [field.dataset.labControl]: value }));
  }
  function click(event) {
    const button = event.target?.closest?.("[data-lab-play], [data-lab-step], [data-lab-step-back], [data-lab-reset-args], [data-lab-restart]");
    if (!button || !root.contains(button)) return;
    if (button.hasAttribute("data-lab-play")) run(store.getSnapshot().playback.playing ? store.pause() : store.play());
    else if (button.hasAttribute("data-lab-step")) run(store.advance());
    else if (button.hasAttribute("data-lab-step-back")) run(store.seekFrame(Math.max(0, store.getSnapshot().playback.frame - 1)));
    else if (button.hasAttribute("data-lab-restart")) run(store.restart());
    else run(store.resetArgs());
  }
  root.addEventListener("input", edit); root.addEventListener("change", edit); root.addEventListener("click", click);
  return { destroy() { subscribe(); root.removeEventListener("input", edit); root.removeEventListener("change", edit); root.removeEventListener("click", click); } };
}

// Carry compatible edits across HMR while letting changed schemas use defaults.
export function restoreStoryArgs(story, args = {}) {
  const restored = {};
  for (const [name, value] of Object.entries(args)) {
    const control = story.controls?.[name];
    if (!control && !(name in (story.args || {}))) continue;
    if (control?.type === "number" && (!Number.isFinite(value) || (control.min != null && value < control.min) || (control.max != null && value > control.max))) continue;
    if ((control?.type === "text" || control?.type === "color") && typeof value !== "string") continue;
    if (control?.type === "boolean" && typeof value !== "boolean") continue;
    if (control?.type === "select" && !control.options.some(option => (typeof option === "object" ? option.value : option) === value)) continue;
    restored[name] = structuredClone(value);
  }
  return restored;
}

// Magnets use screen pixels, with hysteresis to avoid jitter at any zoom.
export function snapViewportPan(pan, {width,height,stageWidth,stageHeight,guideTargets={},config={}}, previous={}, bypass=false) {
  if(bypass)return {...pan,guides:{}};
  const guides={}, result={...pan,guides};
  for(const [axis,size,stage] of [['x',width,stageWidth],['y',height,stageHeight]]) {
    const targets={}; if(config.center!==false)targets.center=0; if(config.edges!==false){targets.start=40+size/2-stage/2;targets.end=stage/2-40-size/2;} if(config.guides!==false)Object.assign(targets,guideTargets[axis]); if(!Object.keys(targets).length)continue; const held=previous[axis],distance=Number.isFinite(config.distance)?Math.max(1,Math.min(32,config.distance)):8;
    const choice=held&&Math.abs(pan[axis]-targets[held])<=distance+6?held:Object.keys(targets).sort((a,b)=>Math.abs(pan[axis]-targets[a])-Math.abs(pan[axis]-targets[b]))[0];
    if(Math.abs(pan[axis]-targets[choice])<=(choice===held?distance+6:distance)){result[axis]=targets[choice];guides[axis]=choice;}
  }
  return result;
}
export function rulerStep(unitsPerPixel) {
  const desired=64*unitsPerPixel;
  if(!(desired>0)||!Number.isFinite(desired))return 1;
  const power=10**Math.floor(Math.log10(desired));
  return Math.max(1,[1,2,5,10].find(n=>n*power>=desired)*power);
}
export function installCanvasGuides({root,getSurface,getUnits,preferences={},persist=()=>{}}) {
  const stage=root.querySelector('[data-lab-stage]');
  if(!stage)return {update(){},snap:pan=>pan,clear(){},destroy(){}};
  const doc=root.ownerDocument, canvas=doc.createElement('canvas');
  canvas.className='hydronium-lab__rulers';canvas.dataset.labRulers='';canvas.setAttribute('aria-hidden','true');stage.append(canvas);
  const ctx=canvas.getContext('2d'), abort=new AbortController();
  const layer=doc.createElement('div');layer.className='hydronium-lab__guide-layer';layer.dataset.labGuideLayer='';stage.append(layer);
  const hit=doc.createElement('div');hit.className='hydronium-lab__ruler-hit';hit.dataset.labRulerHit='';hit.setAttribute('aria-label','Drag rulers to create guides');stage.append(hit);
  let placed=Array.isArray(preferences.canvasGuides)?preferences.canvasGuides.filter(g=>g&&['x','y'].includes(g.axis)&&Number.isFinite(g.value)&&typeof g.id==='string').map(g=>({...g,color:/^#[0-9a-f]{6}$/i.test(g.color)?g.color:'#45d6ba'})):[];
  let selectedGuide, gesture, sequence=0;
  const guideButtons=new Map();
  const unitPixels=new Map();
  let rulerOrigin=['story','top-left','center'].includes(preferences.rulerOrigin)?preferences.rulerOrigin:'story';
  const config={center:preferences.snapCenter!==false,edges:preferences.snapEdges!==false,guides:preferences.snapGuides!==false,distance:Number.isFinite(preferences.snapDistance)?preferences.snapDistance:8};
  let guideColor=/^#[0-9a-f]{6}$/i.test(preferences.guideColor)?preferences.guideColor:'#45d6ba';
  const saveGuides=()=>persist({canvasGuides:placed.map(g=>({...g}))});
  const geometry=()=>{const surface=getSurface(),rect=surface?.getBoundingClientRect(),box=stage.getBoundingClientRect(),units=getUnits?.();if(!rect||!units)return null;
    const world=root.querySelector('[data-lab-viewport]'),worldRect=world?.getBoundingClientRect(),zoom=world?.offsetWidth?worldRect.width/world.offsetWidth:1;
    if(!unitPixels.has(units.label)&&Number.isFinite(units.pixelWidth)&&units.pixelWidth>0&&Number.isFinite(units.pixelHeight)&&units.pixelHeight>0)
      unitPixels.set(units.label,{x:units.pixelWidth,y:units.pixelHeight});
    const fixed=unitPixels.get(units.label)||{x:units.label==='px'?1:surface.offsetWidth/units.width,y:units.label==='px'?1:surface.offsetHeight/units.height};
    const w=stage.clientWidth,h=stage.clientHeight,panX=worldRect?worldRect.left+worldRect.width/2-box.left-w/2:0,panY=worldRect?worldRect.top+worldRect.height/2-box.top-h/2:0;
    return {rect,box,w,h,rx:fixed.x*zoom,ry:fixed.y*zoom,originX:rulerOrigin==='story'?rect.left-box.left:(rulerOrigin==='center'?w/2:24)+panX,originY:rulerOrigin==='story'?rect.top-box.top:(rulerOrigin==='center'?h/2:24)+panY,units:units.label};};
  for(const [name,key] of [['snap-center','center'],['snap-edges','edges'],['snap-guides','guides'],['snap-distance','distance']]){
    const input=root.querySelector(`[data-lab-${name}]`);if(!input)continue;if(key==='distance')input.value=config[key];else input.checked=config[key];
    input.addEventListener('change',()=>{config[key]=key==='distance'?Math.max(1,Math.min(32,Number(input.value)||8)):input.checked;input.value=key==='distance'?config[key]:input.value;persist({[{center:'snapCenter',edges:'snapEdges',guides:'snapGuides',distance:'snapDistance'}[key]]:config[key]});locks={};update();},{signal:abort.signal});
  }
  const colorInput=root.querySelector('[data-lab-guide-color]');
  if(colorInput){colorInput.value=guideColor;colorInput.addEventListener('input',()=>{guideColor=colorInput.value;const current=placed.find(g=>g.id===selectedGuide);if(current){current.color=guideColor;saveGuides();}persist({guideColor});update();},{signal:abort.signal});}
  root.querySelector('[data-lab-clear-guides]')?.addEventListener('click',()=>{placed=[];selectedGuide=null;saveGuides();update();},{signal:abort.signal});
  function position(g,geo){return (g.axis==='x'?geo.originX:geo.originY)+g.value*(g.axis==='x'?geo.rx:geo.ry);}
  function renderGuides(geo){
    hit.hidden=!enabled;
    const visible=placed.filter(g=>(g.units||'px')===geo.units);
    for(const [id,button] of guideButtons)if(!visible.some(g=>g.id===id)){button.remove();guideButtons.delete(id);}
    for(const g of visible){let button=guideButtons.get(g.id);if(!button){button=doc.createElement('button');guideButtons.set(g.id,button);layer.append(button);}button.type='button';button.className=`hydronium-lab__guide hydronium-lab__guide--${g.axis}`;button.dataset.labGuide=g.id;button.setAttribute('aria-label',`${g.axis==='x'?'Vertical':'Horizontal'} guide`);button.style.setProperty('--guide-color',g.color);button.style[g.axis==='x'?'left':'top']=`${position(g,geo)}px`;button.setAttribute('aria-pressed',String(selectedGuide===g.id));}
  }
  function stop(event){event.preventDefault();event.stopImmediatePropagation?.();}
  // Removal is visible at once: the next frame's redraw would otherwise leave
  // a deleted guide's button in the DOM (and clickable) for one more frame.
  function dropGuideButtons(){for(const [id,button] of guideButtons)if(!placed.some(g=>g.id===id)){button.remove();guideButtons.delete(id);}}
  stage.addEventListener('pointerdown',event=>{
    const button=event.target?.closest?.('[data-lab-guide]');const isRuler=event.target===hit;
    if(!button&&!isRuler)return;
    const geo=geometry();if(!geo)return;stop(event);const id=button?.dataset.labGuide;
    if(id&&(event.altKey||event.ctrlKey||event.metaKey)){placed=placed.filter(g=>g.id!==id);dropGuideButtons();saveGuides();update();return;}
    const before=placed.map(g=>({...g}));let ids;
    if(id){ids=[id];button.focus?.();selectedGuide=id;const g=placed.find(g=>g.id===id);if(colorInput)colorInput.value=g.color;}
    else {const x=event.clientX-geo.box.left,y=event.clientY-geo.box.top;const axes=x<24&&y<24?['x','y']:y<24?['y']:['x'];ids=axes.map(axis=>{const id=`guide-${Date.now()}-${sequence++}`;placed.push({id,axis,value:0,color:guideColor,units:geo.units});return id;});selectedGuide=ids[0];}
    const offsets={};if(id){const g=placed.find(g=>g.id===id);offsets[id]=(g.axis==='x'?event.clientX-geo.box.left:event.clientY-geo.box.top)-position(g,geo);}
    gesture={pointer:event.pointerId,ids,before,geo,offsets};stage.setPointerCapture(event.pointerId);if(!id)moveGuide(event);update();
  },{capture:true,signal:abort.signal});
  function moveGuide(event){if(!gesture||event.pointerId!==gesture.pointer)return;stop(event);const geo=geometry();if(!geo)return;for(const id of gesture.ids){const g=placed.find(g=>g.id===id);if(!g)continue;const offset=g.axis==='x'?event.clientX-geo.box.left-geo.originX:event.clientY-geo.box.top-geo.originY;g.value=(offset-(gesture.offsets[id]||0))/(g.axis==='x'?geo.rx:geo.ry);}update();}
  stage.addEventListener('pointermove',moveGuide,{capture:true,signal:abort.signal});
  function finishGuide(event){if(!gesture||event.pointerId!==gesture.pointer)return;stop(event);const geo=geometry(),x=event.clientX-geo.box.left,y=event.clientY-geo.box.top;
    if(event.type==='pointercancel')placed=gesture.before;else if(x<24&&y<24||x<0||y<0||x>geo.w||y>geo.h)placed=placed.filter(g=>!gesture.ids.includes(g.id));
    gesture=null;selectedGuide=placed.some(g=>g.id===selectedGuide)?selectedGuide:null;dropGuideButtons();saveGuides();update();
  }
  for(const type of ['pointerup','pointercancel'])stage.addEventListener(type,finishGuide,{capture:true,signal:abort.signal});
  stage.addEventListener('keydown',event=>{if(event.target?.dataset?.labGuide&&['Delete','Backspace'].includes(event.key)){stop(event);placed=placed.filter(g=>g.id!==event.target.dataset.labGuide);dropGuideButtons();saveGuides();update();}},{signal:abort.signal});
  doc.defaultView.addEventListener?.('blur',()=>{if(gesture){placed=gesture.before;gesture=null;saveGuides();}locks={};update();},{signal:abort.signal});
  root.addEventListener('input',update,{signal:abort.signal});root.addEventListener('change',update,{signal:abort.signal});
  let pending,locks={},alive=true,enabled=preferences.rulers!==false,magnetic=preferences.snapping!==false;
  const originInput=root.querySelector('[data-lab-ruler-origin]');if(originInput){originInput.value=rulerOrigin;originInput.addEventListener('change',()=>{rulerOrigin=['story','top-left','center'].includes(originInput.value)?originInput.value:'story';persist({rulerOrigin});update();},{signal:abort.signal});}
  let hints=preferences.showHints!==false;root.dataset.hintsVisible=String(hints);
  for(const [name,initial] of [['rulers',enabled],['snapping',magnetic]]) {
    const input=root.querySelector(`[data-lab-${name}-enabled]`);if(!input)continue;input.checked=initial;
    input.addEventListener('change',()=>{if(name==='rulers')enabled=input.checked;else {magnetic=input.checked;locks={};}persist({[name]:input.checked});update();},{signal:abort.signal});
  }
  const hintInput=root.querySelector('[data-lab-hints-enabled]');if(hintInput){hintInput.checked=hints;
    hintInput.addEventListener('change',()=>{hints=hintInput.checked;root.dataset.hintsVisible=String(hints);persist({showHints:hints});},{signal:abort.signal});}
  function toggleRulers(){enabled=!enabled;const input=root.querySelector('[data-lab-rulers-enabled]');if(input)input.checked=enabled;persist({rulers:enabled});update();}
  function toggleHints(){hints=!hints;if(hintInput)hintInput.checked=hints;root.dataset.hintsVisible=String(hints);persist({showHints:hints});}
  doc.defaultView.addEventListener?.('keydown',event=>{
    if(event.repeat||event.ctrlKey||event.metaKey||event.altKey||event.target?.closest?.('input,textarea,select,[contenteditable]'))return;
    const key=event.key?.toLowerCase();if(key==='r'){event.preventDefault();toggleRulers();}
    else if(key==='h'){event.preventDefault();toggleHints();}
  },{signal:abort.signal});
  function draw() {
    pending=null;if(!alive||!ctx)return;
    const box=stage.getBoundingClientRect(),rect=getSurface()?.getBoundingClientRect(),w=stage.clientWidth,h=stage.clientHeight,dpr=doc.defaultView.devicePixelRatio||1;
    canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr);ctx.setTransform(dpr,0,0,dpr,0,0);ctx.clearRect(0,0,w,h);
    if(!rect?.width||!rect?.height)return;
    const left=rect.left-box.left,top=rect.top-box.top,units=getUnits?.()||{width:getSurface().offsetWidth,height:getSurface().offsetHeight,label:'px'};
    canvas.dataset.units=units.label;
    const geo=geometry();if(geo)renderGuides(geo);
    const grid=root.querySelector('[data-lab-grid]');
    if(grid&&geo){const gridRect=grid.getBoundingClientRect(),world=root.querySelector('[data-lab-viewport]'),worldRect=world?.getBoundingClientRect(),zoom=world?.offsetWidth?worldRect.width/world.offsetWidth:1;
      grid.style.backgroundPosition=`${(box.left+geo.originX-gridRect.left)/zoom}px ${(box.top+geo.originY-gridRect.top)/zoom}px`;}
    canvas.dataset.snapActive=String(Object.keys(locks).length>0);ctx.strokeStyle='#8eaaff';ctx.setLineDash([4,4]);
    for(const [axis,alignment] of Object.entries(locks)) {
      const origin=axis==='x'?left:top,extent=axis==='x'?rect.width:rect.height,anchor=alignment.split(':').at(-1),position=origin+(anchor==='center'?extent/2:anchor==='end'?extent:0);
      ctx.beginPath();if(axis==='x'){ctx.moveTo(position,24);ctx.lineTo(position,h);}else {ctx.moveTo(24,position);ctx.lineTo(w,position);}ctx.stroke();
    }
    ctx.setLineDash([]);if(!enabled)return;
    ctx.fillStyle='#121a2df2';ctx.fillRect(0,0,w,24);ctx.fillRect(0,0,24,h);ctx.font='10px ui-monospace, monospace';
    // Story origin follows its top-left; explicit canvas origins follow pan.
    // Cell spacing is calibrated once, independently of the resizable box.
    const rulerX=geo.originX,rulerY=geo.originY;
    for(const [axis,origin,extent,count,length] of [['x',rulerX,rect.width,units.width,w],['y',rulerY,rect.height,units.height,h]]) {
      if(!(count>0))continue;
      const ratio=axis==='x'?geo.rx:geo.ry,step=rulerStep(1/ratio),minor=step>=5?step/5:step;
      const previewOrigin=axis==='x'?left:top;
      ctx.fillStyle='#263b60';const startEdge=Math.max(24,previewOrigin),range=Math.max(0,Math.min(length,previewOrigin+extent)-startEdge);
      if(axis==='x')ctx.fillRect(startEdge,20,range,4);else ctx.fillRect(20,startEdge,4,range);
      const start=Math.ceil((24-origin)/ratio/minor),finish=Math.floor((length-origin)/ratio/minor);
      for(let n=start;n<=finish&&n<start+1000;n++) {
        const value=n*minor,pixel=Math.round(origin+value*ratio)+.5,major=Math.abs(value/step-Math.round(value/step))<.001;
        ctx.strokeStyle=major?'#91a2c1':'#475875';ctx.beginPath();if(axis==='x'){ctx.moveTo(pixel,major?15:20);ctx.lineTo(pixel,24);}else {ctx.moveTo(major?15:20,pixel);ctx.lineTo(24,pixel);}ctx.stroke();
        if(major){ctx.fillStyle='#b6c3db';const text=String(Math.round(value));if(axis==='x')ctx.fillText(text,pixel+3,11);else {ctx.save();ctx.translate(11,pixel-3);ctx.rotate(-Math.PI/2);ctx.fillText(text,0,0);ctx.restore();}}
      }
    }
    ctx.fillStyle='#19243b';ctx.fillRect(0,0,24,24);ctx.fillStyle='#b6c3db';ctx.font='9px ui-monospace, monospace';ctx.fillText(units.label==='cells'?'cell':'px',2,15);
  }
  function update(){if(alive&&pending==null)pending=doc.defaultView.requestAnimationFrame(draw);}
  const observer=typeof ResizeObserver==='undefined'?null:new ResizeObserver(update);observer?.observe(stage);const surface=getSurface();if(surface)observer?.observe(surface);update();
  return {update,toggleRulers,toggleHints,resetUnitScale(){unitPixels.clear();update();},clear(){locks={};update();},snap(pan,bypass=false){const rect=getSurface()?.getBoundingClientRect();if(!rect)return pan;
    const geo=geometry(),guideTargets={x:{},y:{}};
    if(geo)for(const g of placed.filter(g=>(g.units||'px')===geo.units)){const size=g.axis==='x'?rect.width:rect.height,target=position(g,geo)-(g.axis==='x'?geo.w:geo.h)/2;for(const [anchor,offset] of [['start',-size/2],['center',0],['end',size/2]])guideTargets[g.axis][`guide:${g.id}:${anchor}`]=target-offset;}
    const result=snapViewportPan(pan,{width:rect.width,height:rect.height,stageWidth:stage.clientWidth,stageHeight:stage.clientHeight,guideTargets,config},locks,bypass||!magnetic);locks=result.guides;update();return {x:result.x,y:result.y};
  },destroy(){alive=false;abort.abort();observer?.disconnect();if(pending!=null)doc.defaultView.cancelAnimationFrame(pending);canvas.remove();layer.remove();hit.remove();}};
}
