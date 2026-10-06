import { viewportGroups } from "./preview-settings.js";
import { installPreviewCanvas, createStoryStore, bindStoryControls, loadProjectPreferences, saveProjectPreferences, installWorkbenchPreferences } from "./workbench.js";

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
    const activeStory=root.querySelector("[data-lab-active-story]");if(activeStory)activeStory.textContent = story.title;
    navigate(); persist({story: story.id});
    for (const timeline of root.querySelectorAll("[data-lab-timeline]")) timeline.hidden = story.renderer !== "ink";
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
    stopped=true; clearInterval(timer); canvas.destroy(); rendererControls.destroy(); binding.destroy(); store.destroy();
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
    else { const snapshot = store.getSnapshot(); selected = current; store.select(current); store.accept({ lab: snapshot }); navigate(); }
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
  const setViewport = async size => {viewport={...size};const index=presets.findIndex(v=>v.width===size.width&&v.height===size.height);if(query('viewport-preset'))query('viewport-preset').value=String(index);await applyDOM();};
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
  const applyInk = async settings => { const bounds=await(await bridge()).configure(settings); if(bounds?.width && bounds?.height)canvas.resize(bounds.width,bounds.height); };
  query('ink-size')?.addEventListener('change',event=>queue(async()=>{const size=inkSizes[Number(event.target.value)];await applyInk(size);await persist({inkSize:size});}),options);
  query('ink-color')?.addEventListener('change',event=>queue(async()=>{await(await bridge()).configure({color:event.target.value});await persist({inkColor:event.target.value});}),options);
  return {async select(story){
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
      const saved=preferences.inkSize,index=inkSizes.findIndex(v=>v.columns===saved?.columns&&v.rows===saved?.rows);if(query('ink-size'))query('ink-size').value=String(Math.max(0,index));
      const bounds = await(await bridge()).configure({...inkSizes[Math.max(0,index)],color:query('ink-color')?.value || preferences.inkColor || story.color || 'truecolor'});
      if(bounds?.width && bounds?.height){getFrame().style.width=`${bounds.width}px`;getFrame().style.height=`${bounds.height}px`;}
    }
  },destroy(){abort.abort();}};
}

export { installPreviewCanvas } from "./workbench.js";
