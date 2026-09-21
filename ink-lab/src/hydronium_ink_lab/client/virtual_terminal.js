const PALETTE_NAMES = [
  "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
  "bright-black", "bright-red", "bright-green", "bright-yellow",
  "bright-blue", "bright-magenta", "bright-cyan", "bright-white",
];

const FALLBACK_PALETTE = [
  "#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
  "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff",
];

function xtermColor(index) {
  if (index < 16) return FALLBACK_PALETTE[index];
  if (index >= 232) {
    const value = 8 + (index - 232) * 10;
    return `rgb(${value} ${value} ${value})`;
  }
  const n = index - 16;
  const levels = [0, 95, 135, 175, 215, 255];
  return `rgb(${levels[Math.floor(n / 36)]} ${levels[Math.floor(n / 6) % 6]} ${levels[n % 6]})`;
}

export function colorToCss(color) {
  if (!color) return null;
  if (color.kind === "rgb") return `rgb(${color.r} ${color.g} ${color.b})`;
  if (color.kind === "index") return xtermColor(color.index);
  const name = PALETTE_NAMES[color.index];
  return `var(--hy-terminal-${name}, ${FALLBACK_PALETTE[color.index]})`;
}

export function keyboardEvent(event) {
  const key = {
    ctrl: event.ctrlKey || false,
    shift: event.shiftKey || false,
    meta: event.metaKey || false,
    tab: event.key === "Tab",
    return: event.key === "Enter",
    escape: event.key === "Escape",
    backspace: event.key === "Backspace",
    delete: event.key === "Delete",
    upArrow: event.key === "ArrowUp",
    downArrow: event.key === "ArrowDown",
    leftArrow: event.key === "ArrowLeft",
    rightArrow: event.key === "ArrowRight",
    pageUp: event.key === "PageUp",
    pageDown: event.key === "PageDown",
    home: event.key === "Home",
    end: event.key === "End",
  };
  let input = event.key.length === 1 ? event.key : "";
  if (event.key === "Enter") input = "\r";
  if (event.key === "Tab") input = "\t";
  if (event.key === "Escape") input = "\x1b";
  return { op: "input", input, key };
}

export function paintFrame(container, frame) {
  if (!frame || frame.version !== 1) throw new Error("hydronium/ink-lab: unsupported frame snapshot");
  container.style.display = "grid";
  container.style.gridTemplateColumns = `repeat(${frame.width}, 1ch)`;
  container.style.gridTemplateRows = `repeat(${frame.height}, 1lh)`;
  container.style.width = `${frame.width}ch`;
  container.style.height = `${frame.height}lh`;
  container.style.whiteSpace = "pre";
  container.style.fontFamily = "var(--hy-terminal-font, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace)";
  container.style.background = "var(--hy-terminal-background, #111318)";
  container.style.color = "var(--hy-terminal-foreground, #e5e7eb)";
  container.dataset.columns = String(frame.width);
  container.dataset.rows = String(frame.height);

  let grid = container.__hydroniumInkGrid;
  if (!grid || grid.width !== frame.width || grid.height !== frame.height) {
    const fragment = container.ownerDocument.createDocumentFragment();
    const cells = [];
    for (let y = 0; y < frame.height; y += 1) for (let x = 0; x < frame.width; x += 1) {
      const span = container.ownerDocument.createElement("span");
      span.style.gridColumn = String(x + 1);
      span.style.gridRow = String(y + 1);
      cells.push(span);
      fragment.appendChild(span);
    }
    container.replaceChildren(fragment);
    grid = { width: frame.width, height: frame.height, cells };
    container.__hydroniumInkGrid = grid;
  }

  const colorKey = (color) => !color ? "" : color.kind === "rgb"
    ? `rgb:${color.r}:${color.g}:${color.b}` : `${color.kind}:${color.index}`;
  frame.rows.forEach((row, y) => row.forEach((cell, x) => {
    const span = grid.cells[y * frame.width + x];
    const cursor = Boolean(frame.cursor && frame.cursor.x === x && frame.cursor.y === y);
    const key = [cell.ch, colorKey(cell.fg), colorKey(cell.bg), cell.bold, cell.dim, cell.italic,
      cell.underline, cell.strikethrough, cell.inverse, cursor].join("|");
    if (span.__hydroniumInkCellKey === key) return;
    span.__hydroniumInkCellKey = key;
    span.textContent = cell.ch === "" ? "" : cell.ch;
    span.style.cssText = `grid-column:${x + 1};grid-row:${y + 1}`;
    let fg = colorToCss(cell.fg);
    let bg = colorToCss(cell.bg);
    if (cell.inverse) [fg, bg] = [bg || "var(--hy-terminal-foreground, #e5e7eb)", fg || "var(--hy-terminal-background, #111318)"];
    if (fg) span.style.color = fg;
    if (bg) span.style.backgroundColor = bg;
    if (cell.bold) span.style.fontWeight = "700";
    if (cell.dim) span.style.opacity = "0.65";
    if (cell.italic) span.style.fontStyle = "italic";
    const decorations = [];
    if (cell.underline) decorations.push("underline");
    if (cell.strikethrough) decorations.push("line-through");
    if (decorations.length) span.style.textDecoration = decorations.join(" ");
    if (cursor) span.dataset.cursor = ""; else delete span.dataset.cursor;
  }));
  return frame;
}

function query(root, role) {
  return root.querySelector(`[data-lab-${role}]`);
}

function normalizedSearch(value) {
  return String(value || "").toLocaleLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g, "");
}

// A compact trigram matcher keeps story navigation useful once a lab grows:
// short queries remain familiar substring searches, while longer queries may
// match the title's word-boundary padded trigrams in any order.
function matchesStorySearch(title, rawQuery) {
  const query = normalizedSearch(rawQuery).replace(/\s+/g, " ").trim();
  if (!query) return true;
  const candidate = normalizedSearch(title);
  if (query.length < 3) return candidate.includes(query);
  const trigrams = new Set();
  for (let index = 0; index <= candidate.length - 3; index += 1) trigrams.add(candidate.slice(index, index + 3));
  for (let index = 0; index <= query.length - 3; index += 1) {
    if (!trigrams.has(query.slice(index, index + 3))) return false;
  }
  return true;
}

function renderDimensionPart(container, value) {
  const digits = String(value).padStart(3, "0");
  const significant = String(value).length;
  const zeroCount = Math.max(0, digits.length - significant);
  if (zeroCount) {
    const zeros = container.ownerDocument.createElement("span");
    zeros.className = "hydronium-ink-lab__dimension-zero";
    zeros.textContent = digits.slice(0, zeroCount);
    container.append(zeros);
  }
  container.append(digits.slice(zeroCount));
}

function renderDimensions(container, columns, rows) {
  if (!container) return;
  container.replaceChildren();
  renderDimensionPart(container, columns);
  const separator = container.ownerDocument.createElement("span");
  separator.className = "hydronium-ink-lab__dimension-separator";
  separator.textContent = "×";
  container.append(separator);
  renderDimensionPart(container, rows);
}

const PREF_DB = "hydronium-ink-lab";
function preferencesFor(key) {
  return new Promise((resolve) => {
    const open = indexedDB.open(PREF_DB, 1);
    open.onupgradeneeded = () => open.result.createObjectStore("projects");
    open.onerror = () => resolve({});
    open.onsuccess = () => {
      const tx = open.result.transaction("projects", "readonly");
      const get = tx.objectStore("projects").get(key);
      get.onsuccess = () => resolve(get.result || {}); get.onerror = () => resolve({});
    };
  });
}
function savePreferences(key, value) {
  const open = indexedDB.open(PREF_DB, 1);
  open.onupgradeneeded = () => open.result.createObjectStore("projects");
  open.onsuccess = () => open.result.transaction("projects", "readwrite").objectStore("projects").put(value, key);
}

/**
 * Enhances the DOM tree emitted by `hydronium_ink_lab.dom.Shell`.
 * `request(message)` is the only transport seam and may call an in-page Lua
 * runtime, `fetch`, a WebSocket RPC, or a Meteorite endpoint.
 */
export async function createInkLab({ root, request, autoResize = false }) {
  if (typeof root === "string") root = document.querySelector(root);
  if (!root) throw new Error("hydronium/ink-lab: root was not found");
  if (typeof request !== "function") throw new Error("hydronium/ink-lab: request must be a function");
  const terminal = query(root, "terminal");
  const storySelect = query(root, "story");
  const storyRoot = query(root, "stories");
  const storySearch = query(root, "story-search");
  const stage = query(root, "stage");
  const status = query(root, "status");
  const viewport = query(root, "viewport");
  const sizeSelect = query(root, "size");
  const colorSelect = query(root, "color");
  const fontSelect = query(root, "font");
  const customFont = query(root, "font-custom");
  const ligatures = query(root, "ligatures");
  const dimensions = query(root, "dimensions");
  const activeStoryLabel = query(root, "active-story");
  const interactionRoot = query(root, "interactions");
  if (!terminal) throw new Error("hydronium/ink-lab: shell has no terminal surface");
  if (stage && status) stage.append(status);
  // Keep the HUD order stable across a live client update and the SSR shell:
  // color profile, size preset, then the resolved terminal dimensions.
  const canvasHud = root.querySelector(".hydronium-ink-lab__canvas-hud");
  if (canvasHud) {
    const colorControl = colorSelect?.closest(".hydronium-ink-lab__icon-control");
    const sizeControl = sizeSelect?.closest(".hydronium-ink-lab__icon-control");
    const canvasActions = canvasHud.querySelector(".hydronium-ink-lab__canvas-actions");
    if (colorControl) canvasHud.append(colorControl);
    if (sizeControl) canvasHud.append(sizeControl);
    if (dimensions) canvasHud.append(dimensions);
    if (canvasActions) canvasHud.append(canvasActions);
  }

  const projectKey = root.dataset.labProject || "hydronium-lab";
  const preferences = await preferencesFor(projectKey);
  const persist = (patch) => { Object.assign(preferences, patch); savePreferences(projectKey, preferences); };
  let catalog = await request({ op: "catalog" });
  let activeStory = catalog.stories.find((story) => story.id === preferences.story) || catalog.stories[0];
  let activeSize = activeStory.sizes[0];
  let fillMode = preferences.sizeMode === "fill";
  let closed = false;
  let paintedRect = null;
  let manualResizeRect = null;
  let manualResizeUntil = 0;
  let frameCellCount = 0;
  let selectionGesture = false;
  let deferredFrame = null;

  function hasTerminalSelection() {
    const selection = window.getSelection?.();
    return Boolean(selection && !selection.isCollapsed
      && (terminal.contains(selection.anchorNode) || terminal.contains(selection.focusNode)));
  }

  function holdPaintForSelection() {
    return selectionGesture || hasTerminalSelection();
  }

  const fontStacks = {
    system: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace",
    "caskaydia-mono": '"CaskaydiaCove Nerd Font Mono", "Caskaydia Cove Nerd Font Mono", ui-monospace, monospace',
    caskaydia: '"CaskaydiaCove Nerd Font", "Caskaydia Cove Nerd Font", ui-monospace, monospace',
    "cascadia-mono": '"Cascadia Mono", CascadiaCode, ui-monospace, monospace',
    jetbrains: '"JetBrainsMono Nerd Font", "JetBrains Mono", ui-monospace, monospace',
    "sf-mono": '"SF Mono", SFMono-Regular, ui-monospace, monospace',
  };
  function applyFont(stack) {
    root.style.setProperty("--hy-terminal-font", stack);
    // A font switch changes the pixel size of `ch`, but it does not mean the
    // author resized the terminal in cells. Capture its new rendered box on
    // the next frame so ResizeObserver will not reinterpret it as a drag.
    window.requestAnimationFrame(() => {
      const rect = terminal.getBoundingClientRect();
      paintedRect = { width: rect.width, height: rect.height };
    });
  }
  function applyLigatures(enabled) {
    terminal.style.fontVariantLigatures = enabled ? "common-ligatures contextual" : "none";
    terminal.style.fontFeatureSettings = enabled ? '"liga" 1, "calt" 1' : '"liga" 0, "calt" 0';
  }
  if (fontSelect && preferences.font) fontSelect.value = preferences.font;
  if (customFont && preferences.customFont) customFont.value = preferences.customFont;
  applyFont(preferences.customFont ? `"${preferences.customFont}", ui-monospace, monospace` : fontStacks[preferences.font] || fontStacks.system);
  if (ligatures) ligatures.checked = preferences.ligatures !== false;
  applyLigatures(preferences.ligatures !== false);
  root.dataset.sidebarCollapsed = preferences.sidebarCollapsed ? "true" : "false";

  if (storySelect) {
    storySelect.replaceChildren(...catalog.stories.map((story) => {
      const option = root.ownerDocument.createElement("option");
      option.value = story.id;
      option.textContent = story.title;
      return option;
    }));
  }

  function fillSizes() {
    if (!sizeSelect) return;
    sizeSelect.replaceChildren(...activeStory.sizes.map((size) => {
      const option = root.ownerDocument.createElement("option");
      option.value = size.name;
      option.textContent = `${size.name} (${size.columns}×${size.rows})`;
      return option;
    }), (() => { const option = root.ownerDocument.createElement("option"); option.value = "fill"; option.textContent = "Fill canvas"; return option; })());
    sizeSelect.value = fillMode ? "fill" : activeSize.name;
  }

  function cellMetrics() {
    const style = getComputedStyle(terminal);
    const fontSize = parseFloat(style.fontSize) || 16;
    const canvas = root.ownerDocument.createElement("canvas");
    const context = canvas.getContext("2d");
    if (context) context.font = `${style.fontWeight} ${fontSize}px ${style.fontFamily}`;
    return {
      width: context?.measureText("0").width || fontSize * .6,
      height: parseFloat(style.lineHeight) || fontSize * 1.2,
    };
  }

  function fillTarget() {
    const rect = stage?.getBoundingClientRect();
    const metrics = cellMetrics();
    // Leave a small breathing room so the resize affordance and box shadow
    // never produce a horizontal/vertical scrollbar inside the canvas.
    return {
      columns: Math.max(1, Math.floor(Math.max(1, (rect?.width || 80) - 32) / metrics.width)),
      rows: Math.max(1, Math.floor(Math.max(1, (rect?.height || 24) - 40) / metrics.height)),
    };
  }

  let fillTimer = null;
  async function applyFill() {
    if (!fillMode || closed) return;
    const target = fillTarget();
    if (target.columns === activeSize.columns && target.rows === activeSize.rows) return;
    activeSize = { name: "fill", ...target };
    paint(await request({ op: "resize", ...target }));
  }

  function fillInteractions() {
    if (!interactionRoot) return;
    // Empty Lua arrays cross the JSON boundary as objects with some encoders.
    // Interactions are optional, so treat any non-array value as an empty
    // list rather than preventing the entire preview from opening.
    const interactions = Array.isArray(activeStory.interactions) ? activeStory.interactions : [];
    interactionRoot.replaceChildren(...interactions.map((name) => {
      const button = root.ownerDocument.createElement("button");
      button.type = "button";
      button.textContent = name;
      button.addEventListener("click", async () => paint(await request({ op: "interaction", name })));
      return button;
    }));
  }

  function fillStories() {
    if (storyRoot) {
      storyRoot.replaceChildren();
      const groups = new Map();
      catalog.stories.forEach((story) => groups.set(story.group || "Stories", [...(groups.get(story.group || "Stories") || []), story]));
      groups.forEach((stories, name) => {
        const visibleStories = stories.filter((story) => matchesStorySearch(story.title, storySearch?.value || ""));
        if (!visibleStories.length) return;
        const group = root.ownerDocument.createElement("section"); group.className = "hydronium-ink-lab__story-group";
        const heading = root.ownerDocument.createElement("h2"); heading.textContent = name; group.append(heading);
        visibleStories.forEach((story) => { const button = root.ownerDocument.createElement("button"); button.type = "button"; button.className = "hydronium-ink-lab__story"; button.textContent = story.title; button.setAttribute("aria-current", String(story.id === activeStory.id)); button.onclick = async () => { activeStory = story; persist({ story: story.id }); fillStories(); await open(); }; group.append(button); });
        storyRoot.append(group);
      });
    }
    if (activeStoryLabel) activeStoryLabel.textContent = activeStory.title;
    if (!storySelect) return;
    storySelect.replaceChildren(...catalog.stories.map((story) => {
      const option = root.ownerDocument.createElement("option");
      option.value = story.id;
      option.textContent = story.title;
      return option;
    }));
    storySelect.value = activeStory.id;
  }

  function paint(frame) {
    // Frame painting replaces the per-cell DOM grid. During a browser text
    // selection that would detach the range on every animation tick and make
    // the next drag jump from the last painted cell. Keep only the latest
    // snapshot until the user releases/clears their selection.
    if (holdPaintForSelection()) {
      deferredFrame = frame;
      return frame;
    }
    paintFrame(terminal, frame);
    // While a browser drag is waiting for its debounced Ink resize, animation
    // frames still arrive. Preserve the user-owned CSS box across those old
    // frames instead of snapping it back to the previous `widthch × heightlh`.
    if (manualResizeRect) {
      terminal.style.width = `${manualResizeRect.width}px`;
      terminal.style.height = `${manualResizeRect.height}px`;
    }
    const rect = terminal.getBoundingClientRect();
    paintedRect = { width: rect.width, height: rect.height };
    frameCellCount = frame.width * frame.height;
    renderDimensions(dimensions, frame.width, frame.height);
    return frame;
  }

  function flushDeferredFrame() {
    if (!deferredFrame || holdPaintForSelection()) return;
    const frame = deferredFrame;
    deferredFrame = null;
    paint(frame);
  }

  async function open() {
    activeSize = activeStory.sizes[0];
    fillSizes();
    fillInteractions();
    if (colorSelect) colorSelect.value = preferences.color || activeStory.color;
    const target = fillMode ? fillTarget() : activeSize;
    activeSize = fillMode ? { name: "fill", ...target } : activeSize;
    return paint(await request({
      op: "open", story: activeStory.id, columns: target.columns, rows: target.rows,
      color: colorSelect?.value || activeStory.color,
    }));
  }

  storySelect?.addEventListener("change", async () => {
    activeStory = catalog.stories.find((story) => story.id === storySelect.value);
    persist({ story: activeStory.id });
    fillStories();
    await open();
  });
  sizeSelect?.addEventListener("change", async () => {
    if (sizeSelect.value === "fill") {
      fillMode = true;
      persist({ sizeMode: "fill" });
      terminal.style.resize = "none";
      manualResizeRect = null;
      await applyFill();
      return;
    }
    fillMode = false;
    persist({ sizeMode: "preset" });
    if (autoResize) terminal.style.resize = "both";
    activeSize = activeStory.sizes.find((size) => size.name === sizeSelect.value);
    paint(await request({ op: "resize", columns: activeSize.columns, rows: activeSize.rows }));
  });
  colorSelect?.addEventListener("change", async () => {
    persist({ color: colorSelect.value });
    paint(await request({ op: "color", color: colorSelect.value }));
  });
  fontSelect?.addEventListener("change", () => {
    if (customFont) customFont.value = "";
    applyFont(fontStacks[fontSelect.value] || fontStacks.system);
    persist({ font: fontSelect.value, customFont: "" });
  });
  customFont?.addEventListener("input", () => {
    const family = customFont.value.trim();
    if (!family) {
      applyFont(fontStacks[fontSelect?.value] || fontStacks.system);
      return;
    }
    if (fontSelect) fontSelect.value = "";
    applyFont(`"${family.replaceAll('"', "")}", ui-monospace, monospace`);
    persist({ customFont: family, font: "" });
  });
  ligatures?.addEventListener("change", () => { applyLigatures(ligatures.checked); persist({ ligatures: ligatures.checked }); });
  terminal.addEventListener("keydown", async (event) => {
    if (event.metaKey && !event.ctrlKey) return;
    selectionGesture = false;
    window.getSelection?.().removeAllRanges();
    flushDeferredFrame();
    event.preventDefault();
    paint(await request(keyboardEvent(event)));
  });
  terminal.addEventListener("paste", async (event) => {
    event.preventDefault();
    paint(await request({ op: "paste", text: event.clipboardData?.getData("text") || "" }));
  });
  // ResizeObserver alone cannot distinguish a browser layout/font change from
  // a user grabbing CSS's native resize handle. Arm it only from the small
  // lower-right affordance and leave a short window for the final observer
  // delivery after pointer-up.
  terminal.addEventListener("pointerdown", (event) => {
    const rect = terminal.getBoundingClientRect();
    const onResizeHandle = event.clientX >= rect.right - 24 && event.clientY >= rect.bottom - 24;
    if (onResizeHandle) manualResizeUntil = performance.now() + 1800;
    else selectionGesture = true;
  });
  window.addEventListener("pointerup", () => {
    selectionGesture = false;
    window.requestAnimationFrame(flushDeferredFrame);
  });
  document.addEventListener("selectionchange", () => {
    if (!hasTerminalSelection()) window.requestAnimationFrame(flushDeferredFrame);
  });
  const setSidebar = (collapsed) => { root.dataset.sidebarCollapsed = String(collapsed); root.querySelectorAll("[data-lab-sidebar-toggle]").forEach((button) => { button.setAttribute("aria-expanded", String(!collapsed)); button.setAttribute("aria-label", collapsed ? "Show stories" : "Hide stories"); }); persist({ sidebarCollapsed: collapsed }); };
  root.querySelectorAll("[data-lab-sidebar-toggle]").forEach((button) => button.addEventListener("click", () => setSidebar(root.dataset.sidebarCollapsed !== "true")));
  const preferencesPanel = query(root, "preferences");
  const setPreferencesOpen = (open) => { if (preferencesPanel) preferencesPanel.hidden = !open; root.querySelectorAll("[data-lab-preferences-toggle]").forEach((button) => button.setAttribute("aria-expanded", String(open))); };
  root.querySelectorAll("[data-lab-preferences-toggle]").forEach((button) => button.addEventListener("click", () => setPreferencesOpen(preferencesPanel?.hidden)));
  query(root, "preferences-close")?.addEventListener("click", () => setPreferencesOpen(false));

  let zoom = preferences.zoom || 1, pan = preferences.pan || { x: 0, y: 0 };
  const applyView = () => { if (viewport) viewport.style.transform = `translate(${pan.x}px, ${pan.y}px) scale(${zoom})`; };
  const setZoom = (value) => { zoom = Math.max(.5, Math.min(2.5, value)); applyView(); persist({ zoom, pan }); };
  query(root, "zoom-in")?.addEventListener("click", () => setZoom(zoom + .1)); query(root, "zoom-out")?.addEventListener("click", () => setZoom(zoom - .1)); query(root, "canvas-reset")?.addEventListener("click", () => { pan = { x: 0, y: 0 }; setZoom(1); }); applyView();
  storySearch?.addEventListener("input", fillStories);
  let space = false, drag = null;
  window.addEventListener("keydown", (event) => { if (event.code === "Space" && document.activeElement === stage) { space = true; event.preventDefault(); } }); window.addEventListener("keyup", (event) => { if (event.code === "Space") space = false; });
  stage?.addEventListener("pointerdown", (event) => { if (event.target !== stage || !(space || event.pointerType !== "mouse")) return; drag = { x: event.clientX, y: event.clientY, pan: { ...pan } }; stage.dataset.panning = "true"; stage.setPointerCapture(event.pointerId); event.preventDefault(); });
  stage?.addEventListener("pointermove", (event) => { if (!drag) return; pan = { x: drag.pan.x + event.clientX - drag.x, y: drag.pan.y + event.clientY - drag.y }; applyView(); });
  stage?.addEventListener("pointerup", () => { if (!drag) return; drag = null; delete stage.dataset.panning; persist({ zoom, pan }); });
  stage?.addEventListener("keydown", (event) => {
    if (event.target !== stage) return;
    if (event.key.toLowerCase() === "c" && !event.ctrlKey && !event.metaKey && !event.altKey) { pan = { x: 0, y: 0 }; applyView(); persist({ zoom, pan }); event.preventDefault(); }
    if ((event.ctrlKey || event.metaKey) && (event.key === "+" || event.key === "=")) { setZoom(zoom + .1); event.preventDefault(); }
    if ((event.ctrlKey || event.metaKey) && event.key === "-") { setZoom(zoom - .1); event.preventDefault(); }
    if (event.key.toLowerCase() === "f" && !event.ctrlKey && !event.metaKey && !event.altKey) {
      if (document.fullscreenElement) document.exitFullscreen(); else stage.requestFullscreen?.();
      event.preventDefault();
    }
  });

  let observer = null;
  let resizeTimer = null;
  let pendingResize = null;
  function enableAutoResize() {
    if (!autoResize || typeof ResizeObserver === "undefined") return;
    terminal.style.resize = fillMode ? "none" : "both";
    terminal.style.overflow = "hidden";
    observer = new ResizeObserver(([entry]) => {
      // `paintFrame` itself sets width/height in `ch`/`lh`. Ignore the
      // corresponding observation: only a box that differs from the last
      // painted box represents a browser resize-handle gesture.
      if (fillMode || performance.now() > manualResizeUntil || (paintedRect && Math.abs(entry.contentRect.width - paintedRect.width) < 1
        && Math.abs(entry.contentRect.height - paintedRect.height) < 1)) return;
      const style = getComputedStyle(terminal);
      const fontSize = parseFloat(style.fontSize) || 16;
      const lineHeight = parseFloat(style.lineHeight) || fontSize * 1.2;
      // Canvas gives us the chosen system font's real cell width. The former
      // `fontSize * .6` approximation could disagree with CSS `ch`, causing
      // a ResizeObserver feedback loop after every paint.
      const canvas = root.ownerDocument.createElement("canvas");
      const context = canvas.getContext("2d");
      if (context) context.font = `${style.fontWeight} ${fontSize}px ${style.fontFamily}`;
      const cellWidth = context?.measureText("0").width || fontSize * 0.6;
      const columns = Math.max(1, Math.round(entry.contentRect.width / cellWidth));
      const rows = Math.max(1, Math.floor(entry.contentRect.height / lineHeight));
      if (closed || (columns === activeSize.columns && rows === activeSize.rows)
        || (pendingResize && columns === pendingResize.columns && rows === pendingResize.rows)) return;
      manualResizeRect = { width: entry.contentRect.width, height: entry.contentRect.height };
      pendingResize = { columns, rows };
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(async () => {
        const target = pendingResize;
        pendingResize = null;
        if (!target || closed || (target.columns === activeSize.columns && target.rows === activeSize.rows)) return;
        activeSize = { name: "custom", columns: target.columns, rows: target.rows };
        const frame = await request({ op: "resize", columns: target.columns, rows: target.rows });
        manualResizeRect = null;
        paint(frame);
      }, 140);
    });
    observer.observe(terminal);
  }

  // The first observation of an empty terminal has a browser-dependent
  // content rectangle. Paint the story's declared default frame first, then
  // begin translating real user resizes into terminal-cell dimensions.
  fillStories();
  await open();
  enableAutoResize();
  let fillObserver = null;
  if (typeof ResizeObserver !== "undefined" && stage) {
    fillObserver = new ResizeObserver(() => {
      if (!fillMode) return;
      window.clearTimeout(fillTimer);
      fillTimer = window.setTimeout(() => { applyFill(); }, 90);
    });
    fillObserver.observe(stage);
  }
  root.querySelectorAll(".hydronium-ink-lab__icon-control").forEach((control) => control.addEventListener("click", (event) => {
    const select = control.querySelector("select");
    if (!select || event.target === select) return;
    event.preventDefault();
    if (typeof select.showPicker === "function") select.showPicker(); else { select.focus(); select.click(); }
  }));
  // A full Ink snapshot contains one styled record per cell. `setInterval`
  // used to enqueue another `step` every 160ms even if a large snapshot was
  // still encoding, painting, or waiting behind a resize. That created an
  // unbounded serialized-request backlog: shrinking the terminal was queued
  // behind its own animation frames. Schedule the next tick only after the
  // previous one settles, and lower the cadence for genuinely large canvases.
  let animationTimer = null;
  const animationDelay = () => frameCellCount > 12000 ? 900 : frameCellCount > 4000 ? 400 : 160;
  const scheduleAnimation = () => {
    window.clearTimeout(animationTimer);
    animationTimer = window.setTimeout(async () => {
      if (closed) return;
      if (!document.hidden) {
        try {
          paint(await request({ op: "step", nowMs: performance.now() }));
        } catch (_) {
          // The transport's visible status surface reports real failures. A
          // transient animation tick must not unmount the last good frame.
        }
      }
      if (!closed) scheduleAnimation();
    }, animationDelay());
  };
  scheduleAnimation();
  return {
    catalog,
    terminal,
    resize: async (columns, rows) => paint(await request({ op: "resize", columns, rows })),
    input: async (input, key = {}) => paint(await request({ op: "input", input, key })),
    paste: async (text) => paint(await request({ op: "paste", text })),
    step: async (nowMs) => paint(await request({ op: "step", nowMs })),
    // A host supplies only a fully validated catalog. Keep the last painted
    // frame until that point, then remount the selected story at the existing
    // dimensions/color. If it disappeared, fall back deterministically.
    refresh: async (nextCatalog) => {
      if (!nextCatalog || !Array.isArray(nextCatalog.stories) || nextCatalog.stories.length === 0) {
        throw new Error("hydronium/ink-lab: refreshed catalog is invalid");
      }
      const selected = nextCatalog.stories.find((story) => story.id === activeStory.id)
        || nextCatalog.stories[0];
      const previousSize = activeSize;
      const previousColor = colorSelect?.value || activeStory.color;
      catalog = nextCatalog;
      activeStory = selected;
      fillStories();
      fillSizes();
      const matchedSize = activeStory.sizes.find((size) => size.name === previousSize.name)
        || { name: "custom", columns: previousSize.columns, rows: previousSize.rows };
      activeSize = matchedSize;
      if (sizeSelect && activeStory.sizes.some((size) => size.name === matchedSize.name)) sizeSelect.value = matchedSize.name;
      fillInteractions();
      if (colorSelect) colorSelect.value = previousColor;
      return paint(await request({
        op: "open", story: activeStory.id, columns: activeSize.columns, rows: activeSize.rows,
        color: previousColor,
      }));
    },
    close: async () => {
      closed = true;
      window.clearTimeout(resizeTimer);
      window.clearTimeout(fillTimer);
      window.clearTimeout(animationTimer);
      observer?.disconnect();
      fillObserver?.disconnect();
      return request({ op: "close" });
    },
  };
}
