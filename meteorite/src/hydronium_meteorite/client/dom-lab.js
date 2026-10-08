import { viewportGroups } from "./preview-settings.js";
import { installPreviewCanvas, createStoryStore, bindStoryControls, loadProjectPreferences, saveProjectPreferences, installWorkbenchPreferences, stableJSON } from "./workbench.js";

// A failed dynamic import stays failed for the page's lifetime (the module
// map caches the error), so after a dev-server restart retry under a fresh
// URL, and never keep a rejected promise.
let virtualTerminal;
const loadVirtualTerminal = () => virtualTerminal ??= import("./virtual_terminal.js")
  .catch(() => import(`./virtual_terminal.js?retry=${Date.now()}`))
  .catch(error => { virtualTerminal = undefined; throw error; });

const instances = new WeakMap();
export function createDomLab(options) {
  const current = instances.get(options.root);
  if (current) return current;
  const pending = createDomLabInstance(options).catch(error => { instances.delete(options.root); throw error; });
  instances.set(options.root, pending);
  return pending;
}
async function createDomLabInstance({ root, fetchCatalog, previewUrl, loadModules, pollMs = 750 }) {
  let frame = root.querySelector("[data-lab-dom-preview]");
  const nav = root.querySelector("[data-lab-stories]");
  const search = root.querySelector("[data-lab-story-search]");
  const status = root.querySelector("[data-lab-status]") || {textContent:""};
  if (!frame) throw new Error("Lab requires a DOM preview surface");
  const key = root.dataset.labProject || "hydronium-lab";
  let catalog = await fetchCatalog(), selected, stopped = false, updateTail = Promise.resolve(), pendingSelection;
  const preferences = await loadProjectPreferences(key);
  const persist = patch => { Object.assign(preferences, patch); return saveProjectPreferences(key, preferences); };
  const preferenceBinding = installWorkbenchPreferences({ root, preferences, persist: () => persist({}) });
  const bridge = async () => {
    const current = frame.contentWindow?.hydroniumLabPreview;
    if (!current) throw new Error("Preview is still loading");
    return current;
  };
  let operationTail = Promise.resolve();
  const store = createStoryStore({ send: message => { const next = operationTail.then(async () => (await bridge()).request(message)); operationTail = next.catch(() => {}); return next; } });
  const binding = bindStoryControls({ root, store });
  // An Ink preview reports its playback as it runs (ink-preview.js).
  const previewState = event => {
    if (event.source !== frame.contentWindow || event.origin !== location.origin || event.data?.type !== "hydronium-lab-preview-state") return;
    if (selected?.renderer === "ink" && event.data.lab) store.accept({ lab: event.data.lab });
  };
  window.addEventListener("message", previewState);
  const canvas = installPreviewCanvas(root, () => frame, {preferences, persist});
  const rendererControls = installRendererControls({ root, getFrame: () => frame, preferences, persist, bridge, getStory: () => selected, canvas, report });
  function report(error) { status.textContent = `Update failed — showing last preview: ${error.message}`; }
  // Runs on every catalog poll, so buttons are reconciled by story id rather
  // than recreated: a click whose press spans a poll must still land.
  function navigate() {
    if (!nav) return;
    const query = (search?.value || "").toLowerCase();
    const existing = new Map([...nav.children].map(button => [button.dataset.labStory, button]));
    const wanted = [];
    for (const story of catalog.catalog.stories) {
      if (!(story.title + " " + (story.group || "") + " " + story.id).toLowerCase().includes(query)) continue;
      let button = existing.get(story.id);
      if (!button) {
        button = root.ownerDocument.createElement("button");
        button.type = "button"; button.className = "hydronium-lab__story";
        button.dataset.labStory = story.id;
      }
      const label = `${story.group ? story.group + " / " : ""}${story.title} · ${story.renderer}`;
      if (button.textContent !== label) button.textContent = label;
      button.setAttribute("aria-current", String(selected?.id === story.id));
      // A selection that fails (the dev server restarting after an edit) is
      // retried by the next successful poll instead of being dropped.
      button.onclick = () => { pendingSelection = undefined; updateTail = updateTail.then(() => select(story)).catch(error => { pendingSelection = story.id; report(error); }); };
      wanted.push(button);
    }
    wanted.forEach((button, index) => { if (nav.children[index] !== button) nav.insertBefore(button, nav.children[index] || null); });
    while (nav.children.length > wanted.length) nav.lastElementChild.remove();
  }
  async function select(story) {
    if (selected?.id === story.id) return;
    await operationTail;
    status.textContent = "Loading preview…";
    let retired;
    if (selected?.renderer === story.renderer) {
      await (await bridge()).request({op: "open", story: story.id});
    } else {
      const previous = frame;
      const candidate = previous.cloneNode(false);
      candidate.removeAttribute("src");
      candidate.removeAttribute("data-lab-dom-preview");
      candidate.style.visibility = "hidden";
      candidate.style.position = "absolute";
      previous.parentNode.append(candidate);
      try {
        await new Promise((resolve, reject) => {
          // The Lab server restarts when story sources change; a preview
          // requested during that window loads an error page instead of a
          // preview and never reports ready. Reload in that case at once, and
          // reload a real preview page that loaded but stays silent for 10 s
          // (one of its own module imports failed in that window), within
          // the overall limit.
          let attempt = 0, retry;
          const load = () => { const url = new URL(previewUrl(story), location.href); if (attempt) url.searchParams.set("attempt", String(attempt)); attempt += 1; candidate.src = url.pathname + url.search; };
          const loaded = () => {
            let preview = false;
            try { preview = !!candidate.contentDocument?.querySelector("[data-lab-base-path]"); } catch {}
            clearTimeout(retry); retry = setTimeout(load, preview ? 10000 : 500);
          };
          candidate.addEventListener("load", loaded);
          const cleanup = () => { window.removeEventListener("message", ready); candidate.removeEventListener("load", loaded); clearTimeout(timer); clearTimeout(retry); };
          const ready = event => {
            if (event.source !== candidate.contentWindow || event.origin !== location.origin || event.data?.type !== "hydronium-lab-preview-ready") return;
            cleanup(); event.data.error ? reject(new Error(event.data.error)) : resolve();
          };
          const timer = setTimeout(() => { cleanup(); reject(new Error("Preview did not become ready")); }, 30000);
          window.addEventListener("message", ready);
          load();
        });
        frame = candidate;
        retired = previous;
      } catch (error) { candidate.remove(); throw error; }
    }
    // Show the new preview before sizing it: xterm does not paint while its
    // frame is hidden, and a terminal resized then stayed blank until Reset.
    if (retired) { frame.setAttribute("data-lab-dom-preview", ""); frame.style.position = retired.style.position; frame.style.visibility = ""; retired.remove(); }
    // Renderer-specific chrome changes with the visible preview.
    for (const timeline of root.querySelectorAll("[data-lab-timeline]")) timeline.hidden = story.renderer !== "ink";
    await rendererControls.select(story);
    canvas.fit();
    selected = story;
    store.select(story);
    const activeStory=root.querySelector("[data-lab-active-story]");if(activeStory)activeStory.textContent = story.title;
    navigate(); persist({story: story.id});
    store.accept(await (await bridge()).snapshot());
    status.textContent = "Connected";
  }
  const click = event => {
    if (event.target.closest("[data-lab-dom-restart]")) store.restart().catch(report);
  };
  root.addEventListener("click", click); search?.addEventListener("input", navigate);
  const first = catalog.catalog.stories.find(story => story.id === preferences.story) || catalog.catalog.stories[0];

  let timer;
  function destroy() {
    stopped=true; clearInterval(timer); window.removeEventListener("message", previewState); canvas.destroy(); rendererControls.destroy(); binding.destroy(); store.destroy();
    preferenceBinding?.destroy(); root.removeEventListener("click",click); search?.removeEventListener("input",navigate);
    frame.src="about:blank"; instances.delete(root);
  }
  try {
  if (!first) throw new Error("No stories found");
  updateTail = select(first);
  await updateTail;
  let sources = await loadModules();
  async function refresh() {
    if (stopped || root.ownerDocument.hidden) return;
    const next = await fetchCatalog();
    if (next.error) throw new Error(next.error);
    const nextSources = await loadModules();
    const changed = {};
    for (const [id, source] of Object.entries(nextSources.modules)) {
      if (sources.modules[id] !== source) changed[id] = source;
    }
    if (Object.keys(changed).length && selected.renderer === "dom") {
      // The entry rebuilds the registry after a dependency hot replacement.
      changed["hydronium_lab.dom_stories"] = nextSources.modules["hydronium_lab.dom_stories"];
      await (await bridge()).replace(changed);
      store.accept(await (await bridge()).snapshot());
    }
    if (selected.renderer === "dom" && sources.styles_revision !== nextSources.styles_revision) (await bridge()).reloadStyles();
    sources = nextSources;
    catalog = next;
    const current = next.catalog.stories.find(story => story.id === selected.id);
    if (!current || current.renderer !== selected.renderer) await select(current || next.catalog.stories[0]);
    // Re-select only when the story's definition changed: re-selecting
    // rebuilds the inspector, which would take focus from a control being
    // edited (this runs on every poll).
    else if (stableJSON([current.title, current.description, current.args, current.controls]) !== stableJSON([selected.title, selected.description, selected.args, selected.controls])) {
      const snapshot = store.getSnapshot(); selected = current; store.select(current); store.accept({ lab: snapshot }); navigate();
    } else selected = current;
    if (pendingSelection) {
      const story = next.catalog.stories.find(candidate => candidate.id === pendingSelection);
      pendingSelection = undefined;
      if (story) { try { await select(story); } catch (error) { pendingSelection = story.id; throw error; } }
    }
    // A poll that failed while the server restarted recovers on its own.
    if (status.textContent.startsWith("Update failed")) status.textContent = "Connected";
  }
  timer = setInterval(() => { updateTail = updateTail.then(refresh).catch(report); }, pollMs);
  return { state: store, select, refresh, destroy };
  } catch(error) { destroy(); throw error; }
}

const roots = typeof document === "undefined" ? [] : document.querySelectorAll("[data-hydronium-dom-lab]");
await Promise.all([...roots].map(async root => {
  const base = (root.dataset.labBasePath || "/__hydronium/lab").replace(/\/$/, "");
  const json = async url => { const response = await fetch(url, { cache: "no-store" }); const value = await response.json(); if (!response.ok || value.ok === false) throw new Error(value.message || `HTTP ${response.status}`); return value; };
  try {
    const lab = await createDomLab({ root,
      fetchCatalog: () => json(base + "/catalog"),
      loadModules: () => json(base + "/dom/modules"),
      previewUrl: story => base + (story.renderer === "ink" ? "/ink/preview" : "/dom/preview") + "?story=" + encodeURIComponent(story.id),
    });
    window.addEventListener("pagehide", () => lab.destroy(), { once: true });
  } catch (error) { const status=root.querySelector("[data-lab-status]");if(status)status.textContent=error.message;else console.error(error); }
}));
// The canvas transforms the preview as a unit; renderer coordinates stay local.
function installRendererControls({root,getFrame,preferences,persist,bridge,getStory,canvas,report}) {
  const doc=root.ownerDocument, abort=new AbortController(),options={signal:abort.signal};
  let viewport, presets=[], inkSizes=[];
  const query = name => root.querySelector(`[data-lab-${name}]`);
  const fill = (select,groups,format) => {if(!select)return groups.flatMap(group=>group.sizes);select.replaceChildren();let flat=[];for(const group of groups){const node=doc.createElement('optgroup');node.label=group.label;for(const size of group.sizes){const option=doc.createElement('option');option.value=String(flat.length);option.textContent=format(size);node.append(option);flat.push(size);}select.append(node);}return flat;};
  const queue = action => action().catch(report);
  // A size that matches no preset shows as "Custom · W×H" in the picker.
  const choose=(select,index,label)=>{
    if(!select)return; let custom=select.querySelector('option[data-custom]');
    if(index>=0){ if(custom)custom.remove(); select.value=String(index); return; }
    if(!custom){custom=doc.createElement('option');custom.dataset.custom='';custom.value='custom';custom.disabled=true;select.prepend(custom);}
    custom.textContent=label; select.value='custom';
  };
  // "page" follows the Lab page: its computed color-scheme when it names one
  // scheme (a site theme toggle), otherwise the OS preference.
  const pageScheme = () => {
    const declared = getComputedStyle(doc.documentElement).colorScheme || '';
    const dark = /\bdark\b/.test(declared), light = /\blight\b/.test(declared);
    if (dark !== light) return dark ? 'dark' : 'light';
    return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  };
  const colorScheme = () => { const value = query('color-scheme')?.value || preferences.domColorScheme || 'page'; return value === 'light' || value === 'dark' ? value : pageScheme(); };
  let appliedScheme = null, domActive = false;
  const applyDOM = async () => {
    const resized = getFrame().style.width !== `${viewport.width}px` || getFrame().style.height !== `${viewport.height}px`;
    if(resized) canvas.resize(viewport.width,viewport.height);
    if(query('viewport-width'))query('viewport-width').value=viewport.width;if(query('viewport-height'))query('viewport-height').value=viewport.height;
    preferences.domViewport=viewport;await persist({domViewport:viewport});
    appliedScheme = colorScheme();
    getFrame().style.colorScheme = appliedScheme;
    await (await bridge()).configure({colorSpace:(query('color-space')?.value || preferences.domColorSpace || 'srgb'),vision:(query('vision')?.value || preferences.domVision || 'none'),colorScheme:appliedScheme,width:viewport.width,height:viewport.height});
  };
  const followPage = () => { if (domActive && viewport && colorScheme() !== appliedScheme) queue(applyDOM); };
  const pageObserver = new MutationObserver(followPage);
  pageObserver.observe(doc.documentElement, { attributes: true });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', followPage, options);
  abort.signal.addEventListener('abort', () => pageObserver.disconnect());
  const setViewport = async size => {viewport={...size};const index=presets.findIndex(v=>v.width===size.width&&v.height===size.height);choose(query('viewport-preset'),index,`Custom · ${size.width}×${size.height}`);await applyDOM();};
  query('viewport-preset')?.addEventListener('change',event=>queue(()=>setViewport(presets[Number(event.target.value)])),options);
  for(const dimension of ['width','height'])query('viewport-'+dimension)?.addEventListener('change',()=>queue(async()=>{
    const width=Number(query('viewport-width')?.value || viewport.width),height=Number(query('viewport-height')?.value || viewport.height);
    if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>8192||height>8192)throw Error('Viewport dimensions must be integers from 1 to 8192');
    await setViewport({name:`${width}×${height}`,width,height});
  }),options);
  query('viewport-save')?.addEventListener('click',()=>queue(async()=>{
    const user=(preferences.domViewports||[]).filter(v=>v.width!==viewport.width||v.height!==viewport.height);
    user.push({...viewport,name:`${viewport.width}×${viewport.height}`});await persist({domViewports:user});
    presets=fill(query('viewport-preset'),viewportGroups(getStory(),user),v=>`${v.name} · ${v.width}×${v.height}`);await setViewport(viewport);
  }),options);
  for(const name of ['color-space','vision','color-scheme'])query(name)?.addEventListener('change',()=>queue(async()=>{await persist({domColorSpace:(query('color-space')?.value || preferences.domColorSpace || 'srgb'),domVision:(query('vision')?.value || preferences.domVision || 'none'),domColorScheme:(query('color-scheme')?.value || preferences.domColorScheme || 'page')});await applyDOM();}),options);
  let inkCell = null; // CSS pixels per terminal cell, from the preview's bounds
  const applyInk = async settings => {
    const bounds=await(await bridge()).configure(settings);
    if(bounds?.width && bounds?.height){canvas.resize(bounds.width,bounds.height);if(settings.columns&&settings.rows)inkCell={width:bounds.width/settings.columns,height:bounds.height/settings.rows};}
  };
  const showInkSize = size => {
    if(query('ink-columns') && doc.activeElement!==query('ink-columns')) query('ink-columns').value = String(size.columns).padStart(3,'0');
    if(query('ink-rows') && doc.activeElement!==query('ink-rows')) query('ink-rows').value = String(size.rows).padStart(3,'0');
  };
  // Terminal size: a preset, or custom columns/rows (saved as user presets
  // in preferences.terminalSizes, as custom DOM viewports are).
  let inkSize;
  const setInkSize = async size => {
    inkSize = {name:size.name || `${size.columns}×${size.rows}`, columns:size.columns, rows:size.rows};
    const index = inkSizes.findIndex(v=>v.columns===inkSize.columns&&v.rows===inkSize.rows);
    choose(query('ink-size'),index,`Custom · ${inkSize.columns}×${inkSize.rows}`);
    showInkSize(inkSize);
    await applyInk({columns:inkSize.columns, rows:inkSize.rows});
    await persist({inkSize});
  };
  query('ink-size')?.addEventListener('change',event=>queue(()=>setInkSize(inkSizes[Number(event.target.value)])),options);
  for(const dimension of ['columns','rows'])query('ink-'+dimension)?.addEventListener('change',()=>queue(async()=>{
    const columns=Number(query('ink-columns')?.value || inkSize?.columns), rows=Number(query('ink-rows')?.value || inkSize?.rows);
    if(!Number.isInteger(columns)||!Number.isInteger(rows)||columns<10||rows<4||columns>400||rows>200)throw Error('Terminal size must be 10–400 columns and 4–200 rows');
    await setInkSize({columns, rows});
  }),options);
  query('ink-size-save')?.addEventListener('click',()=>queue(async()=>{
    if(!inkSize) return;
    const user=(preferences.terminalSizes||[]).filter(v=>v.columns!==inkSize.columns||v.rows!==inkSize.rows);
    user.push({name:`${inkSize.columns}×${inkSize.rows}`, columns:inkSize.columns, rows:inkSize.rows});
    await persist({terminalSizes:user});
    const {terminalSizeGroups}=await loadVirtualTerminal();
    inkSizes=fill(query('ink-size'),terminalSizeGroups(getStory(),user),v=>`${v.name} · ${v.columns}×${v.rows}`);
    await setInkSize(inkSize);
  }),options);
  query('ink-color')?.addEventListener('change',event=>queue(async()=>{await(await bridge()).configure({color:event.target.value});await persist({inkColor:event.target.value});}),options);
  // Drag the preview's bottom-right corner to resize it: pixels for a DOM
  // viewport, whole cells for a terminal (as the Ink Lab's resizable box).
  const handle=doc.createElement('div');handle.className='hydronium-lab__resize-handle';handle.dataset.labResizeHandle='';handle.title='Drag to resize';
  const readout=doc.createElement('div');readout.className='hydronium-lab__resize-readout';readout.hidden=true;
  let renderer=null, resizing=null, liveTimer=null;
  // The handle lives in the stage (not the panned/zoomed world layer) and
  // follows the preview's on-screen corner.
  const stage=root.querySelector('[data-lab-stage]');
  const place=()=>{
    const frame=getFrame(); if(!frame||!stage) return;
    if(handle.parentElement!==stage){ if(getComputedStyle(stage).position==='static') stage.style.position='relative'; stage.append(handle,readout); }
    const stageBox=stage.getBoundingClientRect(), frameBox=frame.getBoundingClientRect();
    const right=frameBox.right-stageBox.left+stage.scrollLeft, bottom=frameBox.bottom-stageBox.top+stage.scrollTop;
    handle.style.left=`${right-15}px`;handle.style.top=`${bottom-15}px`;
    readout.style.left=`${right+8}px`;readout.style.top=`${bottom-11}px`;
  };
  // Pan and zoom transform the world layer's style.
  const worldObserver=new MutationObserver(place);
  const frameObserver=new ResizeObserver(place);
  abort.signal.addEventListener('abort',()=>{frameObserver.disconnect();worldObserver.disconnect();handle.remove();readout.remove();});
  window.addEventListener('resize',place,options);
  const clamp=(value,min,max)=>Math.max(min,Math.min(max,value));
  const resizeTarget=(width,height)=>renderer==='ink'&&inkCell
    ? {columns:clamp(Math.round(width/inkCell.width),10,400),rows:clamp(Math.round(height/inkCell.height),4,200)}
    : {width:clamp(Math.round(width),40,8192),height:clamp(Math.round(height),40,8192)};
  const applyTarget=target=>target.columns?setInkSize(target):setViewport({name:`${target.width}×${target.height}`,width:target.width,height:target.height});
  handle.addEventListener('pointerdown',event=>{
    event.preventDefault();event.stopPropagation();
    const frame=getFrame(), scale=frame.getBoundingClientRect().width/frame.offsetWidth||1;
    resizing={id:event.pointerId,x:event.clientX,y:event.clientY,width:frame.offsetWidth,height:frame.offsetHeight,scale};
    handle.setPointerCapture(event.pointerId);handle.dataset.active='';frame.style.pointerEvents='none';readout.hidden=false;
  },options);
  handle.addEventListener('pointermove',event=>{
    if(!resizing||event.pointerId!==resizing.id)return;
    const width=resizing.width+(event.clientX-resizing.x)/resizing.scale, height=resizing.height+(event.clientY-resizing.y)/resizing.scale;
    const target=resizeTarget(width,height); resizing.target=target;
    readout.textContent=target.columns?`${target.columns} × ${target.rows}`:`${target.width} × ${target.height}`;
    if(target.columns) showInkSize(target);
    else { if(query('viewport-width'))query('viewport-width').value=target.width; if(query('viewport-height'))query('viewport-height').value=target.height; }
    canvas.resize(Math.max(40,width),Math.max(40,height));place();
    // Apply about eight times a second while dragging; exactly on release.
    if(!liveTimer) liveTimer=setTimeout(()=>{liveTimer=null;if(resizing?.target)queue(()=>applyTarget(resizing.target));},120);
  },options);
  const finishResize=()=>{
    if(!resizing)return; const target=resizing.target; resizing=null;
    clearTimeout(liveTimer);liveTimer=null;handle.removeAttribute('data-active');getFrame().style.pointerEvents='';readout.hidden=true;
    if(target) queue(()=>applyTarget(target)); else place();
  };
  handle.addEventListener('pointerup',finishResize,options);handle.addEventListener('pointercancel',finishResize,options);
  return {async select(story){
    renderer=story.renderer;
    frameObserver.disconnect();frameObserver.observe(getFrame());worldObserver.disconnect();if(getFrame().parentElement)worldObserver.observe(getFrame().parentElement,{attributes:true,attributeFilter:['style']});queueMicrotask(place);
    for(const el of root.querySelectorAll('[data-lab-dom-tools]'))el.hidden=story.renderer!=='dom';
    for(const el of root.querySelectorAll('[data-lab-ink-tools]'))el.hidden=story.renderer!=='ink';
    domActive=story.renderer==='dom';
    if(story.renderer==='dom'){
      presets=fill(query('viewport-preset'),viewportGroups(story,preferences.domViewports||[]),v=>`${v.name} · ${v.width}×${v.height}`);
      if(query('color-space'))query('color-space').value=['srgb','display-p3','rec2020'].includes(preferences.domColorSpace)?preferences.domColorSpace:'srgb';
      if(query('vision'))query('vision').value=['none','protanopia','deuteranopia','tritanopia','achromatopsia'].includes(preferences.domVision)?preferences.domVision:'none';
      if(query('color-scheme'))query('color-scheme').value=['page','light','dark'].includes(preferences.domColorScheme)?preferences.domColorScheme:'page';
      for(const option of query('color-space')?.options || [])option.disabled=!CSS.supports('color',`color(${option.value} 1 0 0)`);
      const gamut=matchMedia('(color-gamut: rec2020)').matches?'Rec. 2020':matchMedia('(color-gamut: p3)').matches?'P3':'sRGB';
      if(query('gamut-support'))query('gamut-support').textContent=`Display gamut: ${gamut} · target does not emulate hardware`;
      const saved=preferences.domViewport;await setViewport(saved&&presets.find(v=>v.width===saved.width&&v.height===saved.height)||presets[0]);
    }else{
      const {terminalSizeGroups}=await loadVirtualTerminal();
      inkSizes=fill(query('ink-size'),terminalSizeGroups(story,preferences.terminalSizes||[]),v=>`${v.name} · ${v.columns}×${v.rows}`);
      if(query('ink-color'))query('ink-color').value=preferences.inkColor||story.color||'truecolor';
      const saved=preferences.inkSize,index=inkSizes.findIndex(v=>v.columns===saved?.columns&&v.rows===saved?.rows);
      // A saved custom size that is not a preset still applies.
      const start = index >= 0 ? inkSizes[index] : (saved?.columns && saved?.rows ? saved : inkSizes[0]);
      inkSize = {name:start.name, columns:start.columns, rows:start.rows};
      choose(query('ink-size'),index>=0?index:(saved?.columns&&saved?.rows?-1:0),`Custom · ${inkSize.columns}×${inkSize.rows}`);
      showInkSize(inkSize);
      const bounds = await(await bridge()).configure({columns:inkSize.columns,rows:inkSize.rows,color:query('ink-color')?.value || preferences.inkColor || story.color || 'truecolor'});
      if(bounds?.width && bounds?.height){getFrame().style.width=`${bounds.width}px`;getFrame().style.height=`${bounds.height}px`;inkCell={width:bounds.width/inkSize.columns,height:bounds.height/inkSize.rows};}
    }
  },destroy(){abort.abort();}};
}

export { installPreviewCanvas } from "./workbench.js";
