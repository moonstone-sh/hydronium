import { viewportGroups } from "./preview-settings.js";
import { installCanvasGuides, createStoryStore, bindStoryControls, loadProjectPreferences, saveProjectPreferences, installWorkbenchPreferences } from "./workbench.js";

export async function createDomLab({ root, fetchCatalog, previewUrl, loadModules, pollMs = 750 }) {
  let frame = root.querySelector("[data-lab-dom-preview]");
  const nav = root.querySelector("[data-lab-stories]");
  const search = root.querySelector("[data-lab-story-search]");
  const status = root.querySelector("[data-lab-status]");
  const key = root.dataset.labProject || "hydronium-lab";
  let catalog = await fetchCatalog(), selected, stopped = false, updateTail = Promise.resolve();
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
  const canvas = installPreviewCanvas(root, () => frame, {preferences, persist});
  const rendererControls = installRendererControls({ root, getFrame: () => frame, preferences, persist, bridge, getStory: () => selected, canvas, report });
  function report(error) { status.textContent = `Update failed — showing last preview: ${error.message}`; }
  function navigate() {
    const query = search.value.toLowerCase();
    nav.replaceChildren();
    for (const story of catalog.catalog.stories) {
      if (!(story.title + " " + (story.group || "") + " " + story.id).toLowerCase().includes(query)) continue;
      const button = root.ownerDocument.createElement("button");
      button.type = "button"; button.className = "hydronium-lab__story";
      button.textContent = `${story.group ? story.group + " / " : ""}${story.title} · ${story.renderer}`;
      button.dataset.labStory = story.id;
      button.setAttribute("aria-current", String(selected?.id === story.id));
      button.onclick = () => { updateTail = updateTail.then(() => select(story)).catch(report); };
      nav.append(button);
    }
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
          const cleanup = () => { window.removeEventListener("message", ready); clearTimeout(timer); };
          const ready = event => {
            if (event.source !== candidate.contentWindow || event.origin !== location.origin || event.data?.type !== "hydronium-lab-preview-ready") return;
            cleanup(); event.data.error ? reject(new Error(event.data.error)) : resolve();
          };
          const timer = setTimeout(() => { cleanup(); reject(new Error("Preview did not become ready")); }, 30000);
          window.addEventListener("message", ready);
          candidate.src = previewUrl(story);
        });
        frame = candidate;
        retired = previous;
      } catch (error) { candidate.remove(); throw error; }
    }
    try {
      await rendererControls.select(story);
      canvas.fit();
      if (retired) { frame.setAttribute("data-lab-dom-preview", ""); frame.style.position = retired.style.position; frame.style.visibility = ""; retired.remove(); }
    } catch (error) {
      if (retired) { frame.remove(); frame = retired; frame.setAttribute("data-lab-dom-preview", ""); }
      throw error;
    }
    selected = story;
    store.select(story);
    root.querySelector("[data-lab-active-story]").textContent = story.title;
    navigate(); persist({story: story.id});
    for (const timeline of root.querySelectorAll("[data-lab-timeline]")) timeline.hidden = story.renderer !== "ink";
    store.accept(await (await bridge()).snapshot());
    status.textContent = "Connected";
  }
  const click = event => {
    if (event.target.closest("[data-lab-dom-restart]")) store.restart().catch(report);
  };
  root.addEventListener("click", click); search.addEventListener("input", navigate);
  const first = catalog.catalog.stories.find(story => story.id === preferences.story) || catalog.catalog.stories[0];
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
    else { const snapshot = store.getSnapshot(); selected = current; store.select(current); store.accept({ lab: snapshot }); navigate(); }
  }
  const timer = setInterval(() => { updateTail = updateTail.then(refresh).catch(report); }, pollMs);
  return { state: store, select, refresh, destroy() { stopped = true; clearInterval(timer); canvas.destroy(); rendererControls.destroy(); binding.destroy(); store.destroy(); preferenceBinding?.destroy(); root.removeEventListener("click", click); search.removeEventListener("input", navigate); frame.src = "about:blank"; } };
}

const root = typeof document === "undefined" ? null : document.querySelector("[data-hydronium-dom-lab]");
if (root) {
  const base = root.dataset.labBasePath.replace(/\/$/, "");
  const json = async url => { const response = await fetch(url, { cache: "no-store" }); const value = await response.json(); if (!response.ok || value.ok === false) throw new Error(value.message || `HTTP ${response.status}`); return value; };
  try {
    const lab = await createDomLab({ root,
      fetchCatalog: () => json(base + "/catalog"),
      loadModules: () => json(base + "/dom/modules"),
      previewUrl: story => base + (story.renderer === "ink" ? "/ink/preview" : "/dom/preview") + "?story=" + encodeURIComponent(story.id),
    });
    window.addEventListener("pagehide", () => lab.destroy(), { once: true });
  } catch (error) { root.querySelector("[data-lab-status]").textContent = error.message; }
}
// The canvas transforms the preview as a unit; renderer coordinates stay local.
export function installPreviewCanvas(root, getFrame = () => root.querySelector("[data-lab-dom-preview]"), settings = {}) {
  const stage = root.querySelector("[data-lab-stage]");
  let zoom = 1, x = 0, y = 0, space = false, drag, wheelTimer;
  const guides = installCanvasGuides({root, getSurface: getFrame, ...settings, getUnits: () => {
    const frame = getFrame(), terminal = frame.contentDocument?.querySelector('[data-lab-terminal]');
    if(terminal){const columns=Number(terminal.dataset.columns),rows=Number(terminal.dataset.rows),screen=terminal.querySelector('.xterm-screen');
      return {width:columns,height:rows,label:'cells',pixelWidth:screen?.offsetWidth/columns,pixelHeight:screen?.offsetHeight/rows};}
    return {width:parseFloat(frame.style.width)||800,height:parseFloat(frame.style.height)||600,label:'px',pixelWidth:1,pixelHeight:1};
  }});
  const abort = new AbortController(), options = { signal: abort.signal };
  // Transform the world layer, which contains both the grid and preview.
  // Keeping them in one coordinate system also preserves pointer mapping.
  const paint = () => { const world = getFrame().parentElement; world.style.transform = `translate(${x}px, ${y}px) scale(${zoom})`; world.style.transformOrigin = 'center'; guides.update(); };
  const resize = (width,height) => {
    const frame=getFrame(),before=frame.getBoundingClientRect();
    frame.style.width=`${width}px`;frame.style.height=`${height}px`;
    const after=frame.getBoundingClientRect();
    x+=before.left-after.left;y+=before.top-after.top;
    paint();
  };
  const fit = () => { guides.clear(); x = y = 0; zoom = Math.max(.1, Math.min(1, (stage.clientWidth - 48) / (parseFloat(getFrame().style.width) || 800), (stage.clientHeight - 48) / (parseFloat(getFrame().style.height) || 600))); paint(); };
  const reset = () => {guides.clear(); fit();};
  const scale = step => { guides.clear(); zoom = Math.max(.1, Math.min(4, zoom * step)); paint(); };
  root.addEventListener('click', event => {
    const openMenu = event.target.closest("details");
    for (const menu of root.querySelectorAll(".hydronium-lab__toolbar-menu[open]")) if (menu !== openMenu) menu.open = false;
    const target = event.target.closest('button'); if (!target) return;
    if (target.hasAttribute('data-lab-zoom-in')) scale(1.1);
    if (target.hasAttribute('data-lab-zoom-out')) scale(1 / 1.1);
    if (target.hasAttribute('data-lab-canvas-reset')) reset();
    if (target.hasAttribute('data-lab-sidebar-toggle')) { const sidebar=root.querySelector('[data-lab-sidebar]'); sidebar.hidden=!sidebar.hidden; root.dataset.sidebarCollapsed=String(sidebar.hidden); for(const button of root.querySelectorAll('[data-lab-sidebar-toggle]'))button.setAttribute('aria-expanded',String(!sidebar.hidden)); }
    if (target.hasAttribute('data-lab-preferences-toggle') || target.hasAttribute('data-lab-preferences-close')) { const panel=root.querySelector('[data-lab-preferences]'); panel.hidden=target.hasAttribute('data-lab-preferences-close') || !panel.hidden; root.querySelector('[data-lab-preferences-toggle]').setAttribute('aria-expanded',String(!panel.hidden)); }
  }, options);
  root.addEventListener('keydown', event => {
    if(event.key==='Escape') { for(const menu of root.querySelectorAll(".hydronium-lab__toolbar-menu[open]"))menu.open=false; }
    if (event.target.closest('input,textarea,select,[contenteditable]')) return;
    if (event.code==='Space') { space=true; event.preventDefault(); }
    if (event.key.toLowerCase()==='c') reset();
    if ((event.ctrlKey || event.metaKey) && ['+','=','-'].includes(event.key)) { event.preventDefault(); scale(event.key==='-'?1/1.1:1.1); }
    if (event.key.toLowerCase()==='f') { if(document.fullscreenElement)document.exitFullscreen();else stage.requestFullscreen?.(); }
  }, options);
  window.addEventListener('keyup', event => { if(event.code==='Space')space=false; }, options);
  window.addEventListener('blur', () => { space=false; drag=null; guides.clear(); getFrame().style.pointerEvents=''; }, options);
  stage.addEventListener('pointerdown', event => {
    if(!space && event.pointerType!=='touch' && event.button!==1 && event.target.closest('iframe,button,input'))return;
    guides.clear(); drag={id:event.pointerId,x:event.clientX,y:event.clientY,pan:{x,y}};stage.setPointerCapture(event.pointerId);getFrame().style.pointerEvents='none';event.preventDefault();
  }, options);
  stage.addEventListener('pointermove', event => {if(!drag||drag.id!==event.pointerId)return;const pan=guides.snap({x:drag.pan.x+event.clientX-drag.x,y:drag.pan.y+event.clientY-drag.y},event.altKey);x=pan.x;y=pan.y;paint();},options);
  const end = () => { drag=null;guides.clear();getFrame().style.pointerEvents=''; };
  stage.addEventListener('pointerup',end,options);stage.addEventListener('pointercancel',end,options);
  stage.addEventListener('wheel',event=>{if(event.ctrlKey||event.metaKey){event.preventDefault();scale(Math.exp(-event.deltaY*.002));}else if(event.target===stage){event.preventDefault();guides.clear();const unit=event.deltaMode===1?16:event.deltaMode===2?stage.clientHeight:1;x-=event.deltaX*unit;y-=event.deltaY*unit;paint();clearTimeout(wheelTimer);wheelTimer=setTimeout(()=>{const pan=guides.snap({x,y},event.altKey);x=pan.x;y=pan.y;paint();guides.clear();},160);}}, {...options,passive:false});
  return {reset,fit,resize,refresh:paint,destroy(){clearTimeout(wheelTimer);guides.destroy();abort.abort();end();}};
}
function installRendererControls({root,getFrame,preferences,persist,bridge,getStory,canvas,report}) {
  const doc=root.ownerDocument, abort=new AbortController(),options={signal:abort.signal};
  let viewport, presets=[], inkSizes=[];
  const query = name => root.querySelector(`[data-lab-${name}]`);
  const fill = (select,groups,format) => {select.replaceChildren();let flat=[];for(const group of groups){const node=doc.createElement('optgroup');node.label=group.label;for(const size of group.sizes){const option=doc.createElement('option');option.value=String(flat.length);option.textContent=format(size);node.append(option);flat.push(size);}select.append(node);}return flat;};
  const queue = action => action().catch(report);
  const applyDOM = async () => {
    const resized = getFrame().style.width !== `${viewport.width}px` || getFrame().style.height !== `${viewport.height}px`;
    if(resized) canvas.resize(viewport.width,viewport.height);
    query('viewport-width').value=viewport.width;query('viewport-height').value=viewport.height;
    preferences.domViewport=viewport;await persist({domViewport:viewport});
    await (await bridge()).configure({colorSpace:query('color-space').value,vision:query('vision').value,width:viewport.width,height:viewport.height});
  };
  const setViewport = async size => {viewport={...size};const index=presets.findIndex(v=>v.width===size.width&&v.height===size.height);query('viewport-preset').value=String(index);await applyDOM();};
  query('viewport-preset')?.addEventListener('change',event=>queue(()=>setViewport(presets[Number(event.target.value)])),options);
  for(const dimension of ['width','height'])query('viewport-'+dimension)?.addEventListener('change',()=>queue(async()=>{
    const width=Number(query('viewport-width').value),height=Number(query('viewport-height').value);
    if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>8192||height>8192)throw Error('Viewport dimensions must be integers from 1 to 8192');
    await setViewport({name:`${width}×${height}`,width,height});
  }),options);
  query('viewport-save')?.addEventListener('click',()=>queue(async()=>{
    const user=(preferences.domViewports||[]).filter(v=>v.width!==viewport.width||v.height!==viewport.height);
    user.push({...viewport,name:`${viewport.width}×${viewport.height}`});await persist({domViewports:user});
    presets=fill(query('viewport-preset'),viewportGroups(getStory(),user),v=>`${v.name} · ${v.width}×${v.height}`);await setViewport(viewport);
  }),options);
  for(const name of ['color-space','vision'])query(name)?.addEventListener('change',()=>queue(async()=>{await persist({domColorSpace:query('color-space').value,domVision:query('vision').value});await applyDOM();}),options);
  const applyInk = async settings => { const bounds=await(await bridge()).configure(settings); if(bounds?.width && bounds?.height)canvas.resize(bounds.width,bounds.height); };
  query('ink-size')?.addEventListener('change',event=>queue(async()=>{const size=inkSizes[Number(event.target.value)];await applyInk(size);await persist({inkSize:size});}),options);
  query('ink-color')?.addEventListener('change',event=>queue(async()=>{await(await bridge()).configure({color:event.target.value});await persist({inkColor:event.target.value});}),options);
  return {async select(story){
    for(const el of root.querySelectorAll('[data-lab-dom-tools]'))el.hidden=story.renderer!=='dom';
    for(const el of root.querySelectorAll('[data-lab-ink-tools]'))el.hidden=story.renderer!=='ink';
    if(story.renderer==='dom'){
      if(!query('viewport-preset'))return;
      presets=fill(query('viewport-preset'),viewportGroups(story,preferences.domViewports||[]),v=>`${v.name} · ${v.width}×${v.height}`);
      query('color-space').value=['srgb','display-p3','rec2020'].includes(preferences.domColorSpace)?preferences.domColorSpace:'srgb';
      query('vision').value=['none','protanopia','deuteranopia','tritanopia','achromatopsia'].includes(preferences.domVision)?preferences.domVision:'none';
      for(const option of query('color-space').options)option.disabled=!CSS.supports('color',`color(${option.value} 1 0 0)`);
      const gamut=matchMedia('(color-gamut: rec2020)').matches?'Rec. 2020':matchMedia('(color-gamut: p3)').matches?'P3':'sRGB';
      query('gamut-support').textContent=`Display gamut: ${gamut} · target does not emulate hardware`;
      const saved=preferences.domViewport;await setViewport(saved&&presets.find(v=>v.width===saved.width&&v.height===saved.height)||presets[0]);
    }else{
      if(!query('ink-size'))return;
      const {terminalSizeGroups}=await import('./virtual_terminal.js');
      inkSizes=fill(query('ink-size'),terminalSizeGroups(story,preferences.terminalSizes||[]),v=>`${v.name} · ${v.columns}×${v.rows}`);
      query('ink-color').value=preferences.inkColor||story.color||'truecolor';
      const saved=preferences.inkSize,index=inkSizes.findIndex(v=>v.columns===saved?.columns&&v.rows===saved?.rows);query('ink-size').value=String(Math.max(0,index));
      const bounds = await(await bridge()).configure({...inkSizes[Math.max(0,index)],color:query('ink-color').value});
      if(bounds?.width && bounds?.height){getFrame().style.width=`${bounds.width}px`;getFrame().style.height=`${bounds.height}px`;}
    }
  },destroy(){abort.abort();}};
}
