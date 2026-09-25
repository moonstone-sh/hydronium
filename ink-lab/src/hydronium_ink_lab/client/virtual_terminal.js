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

// --- Frame protocol v2: style-interned row runs, full or delta -----------
//
// A "full" frame (`{version:2, kind:"full", width, height, styles, rows}`)
// is self-contained: `styles` is the complete set of styles it references
// (keyed by the small integer id `rows` cells point at), and `rows[y]` is an
// array of `[styleId, [ch, ch, ...]]` runs covering the row left to right.
// A "delta" frame (`{version:2, kind:"delta", base, seq, styles?, changes?,
// cursor, status}`) carries only styles the peer hasn't already been sent
// and only the cells that changed since frame `base`, as `[y, x, styleId,
// [ch, ...]]` row runs -- `changes` and `styles` are both omitted (not sent
// as an empty table) when there is nothing new, which is exactly what an
// idle animation tick looks like.
//
// `createFrameModel()` holds the logical grid (style ids + characters,
// resolved style objects, cursor, status) independently of the DOM, so a
// delta can be *applied* to the model even while painting is deferred for an
// in-progress text selection (see `paint()`/`flushDeferredFrame()` below),
// and only the cells actually touched need to be repainted when it flushes.

const CURSOR_FG_DEFAULT = "var(--hy-terminal-foreground, #e5e7eb)";
const CURSOR_BG_DEFAULT = "var(--hy-terminal-background, #111318)";

export function createFrameModel() {
  return { width: 0, height: 0, styleIds: [], chars: [], styles: new Map(), cursor: null, status: null, seq: 0, dirty: new Set() };
}

function cursorEqual(a, b) {
  if (!a && !b) return true;
  if (!a || !b) return false;
  return a.x === b.x && a.y === b.y;
}

function statusEqual(a, b) {
  if (a === b) return true;
  if (!a || !b) return false;
  return a.exited === b.exited && a.exitReason === b.exitReason && a.closed === b.closed;
}

function markDirty(model, x, y) {
  if (x < 0 || y < 0 || x >= model.width || y >= model.height) return;
  model.dirty.add(y * model.width + x);
}

/**
 * Merges a v2 frame into `model`. Returns `{activity}`: false only for a
 * delta that changed nothing at all (no cells, no cursor, no status) -- the
 * signal the animation pacer backs off on. Throws (with `.desync = true`)
 * when a delta's `base` does not match the model's last applied sequence,
 * so a caller can resync with a fresh `snapshot` request instead of silently
 * painting a corrupt grid.
 */
export function applyFrame(model, frame) {
  if (!frame || frame.version !== 2) throw new Error("hydronium/ink-lab: unsupported frame version");
  if (frame.kind === "full") model.styles = new Map();
  if (frame.styles) {
    for (const [id, style] of Object.entries(frame.styles)) model.styles.set(Number(id), style);
  }
  let activity = false;
  if (frame.kind === "full") {
    model.width = frame.width;
    model.height = frame.height;
    model.styleIds = new Array(frame.width * frame.height);
    model.chars = new Array(frame.width * frame.height);
    model.dirty = new Set();
    for (let y = 0; y < frame.height; y += 1) {
      let x = 0;
      for (const [styleId, chars] of frame.rows[y]) {
        for (const ch of chars) {
          const index = y * frame.width + x;
          model.styleIds[index] = styleId;
          model.chars[index] = ch;
          model.dirty.add(index);
          x += 1;
        }
      }
    }
    activity = true;
  } else if (frame.kind === "delta") {
    if (model.seq !== frame.base) {
      const error = new Error(`hydronium/ink-lab: delta frame base ${frame.base} does not match last known frame ${model.seq}`);
      error.desync = true;
      throw error;
    }
    const changes = Array.isArray(frame.changes) ? frame.changes : [];
    for (const [y, x0, styleId, chars] of changes) {
      let x = x0;
      for (const ch of chars) {
        const index = y * model.width + x;
        model.styleIds[index] = styleId;
        model.chars[index] = ch;
        markDirty(model, x, y);
        x += 1;
      }
    }
    activity = changes.length > 0;
  } else {
    throw new Error(`hydronium/ink-lab: unknown frame kind '${frame.kind}'`);
  }
  if (!cursorEqual(model.cursor, frame.cursor)) {
    if (model.cursor) markDirty(model, model.cursor.x, model.cursor.y);
    if (frame.cursor) markDirty(model, frame.cursor.x, frame.cursor.y);
    model.cursor = frame.cursor || null;
    activity = true;
  }
  if (!statusEqual(model.status, frame.status)) { model.status = frame.status; activity = true; }
  model.seq = frame.seq;
  return { activity };
}

function ensureGridDom(container, model) {
  let grid = container.__hydroniumInkGrid;
  if (!grid || grid.width !== model.width || grid.height !== model.height) {
    const fragment = container.ownerDocument.createDocumentFragment();
    const cells = [];
    for (let y = 0; y < model.height; y += 1) for (let x = 0; x < model.width; x += 1) {
      const span = container.ownerDocument.createElement("span");
      span.style.gridColumn = String(x + 1);
      span.style.gridRow = String(y + 1);
      cells.push(span);
      fragment.appendChild(span);
    }
    container.replaceChildren(fragment);
    grid = { width: model.width, height: model.height, cells };
    container.__hydroniumInkGrid = grid;
  }
  return grid;
}

function paintCell(span, x, y, style, ch, cursorHere) {
  span.textContent = ch === "" || ch == null ? "" : ch;
  span.style.cssText = `grid-column:${x + 1};grid-row:${y + 1}`;
  let fg = colorToCss(style && style.fg);
  let bg = colorToCss(style && style.bg);
  if (style && style.inverse) [fg, bg] = [bg || CURSOR_FG_DEFAULT, fg || CURSOR_BG_DEFAULT];
  if (fg) span.style.color = fg;
  if (bg) span.style.backgroundColor = bg;
  if (style && style.bold) span.style.fontWeight = "700";
  if (style && style.dim) span.style.opacity = "0.65";
  if (style && style.italic) span.style.fontStyle = "italic";
  const decorations = [];
  if (style && style.underline) decorations.push("underline");
  if (style && style.strikethrough) decorations.push("line-through");
  if (decorations.length) span.style.textDecoration = decorations.join(" ");
  if (cursorHere) span.dataset.cursor = ""; else delete span.dataset.cursor;
}

/** Repaints every cell in `model.dirty` and clears it. Container-level grid
 * setup (size, base styling) runs every call; it is cheap and idempotent. */
export function flushFrameModel(container, model) {
  container.style.display = "grid";
  container.style.gridTemplateColumns = `repeat(${model.width}, 1ch)`;
  container.style.gridTemplateRows = `repeat(${model.height}, 1lh)`;
  container.style.width = `${model.width}ch`;
  container.style.height = `${model.height}lh`;
  container.style.whiteSpace = "pre";
  container.style.fontFamily = "var(--hy-terminal-font, ui-monospace, SFMono-Regular, Menlo, Consolas, monospace)";
  container.style.background = "var(--hy-terminal-background, #111318)";
  container.style.color = "var(--hy-terminal-foreground, #e5e7eb)";
  container.dataset.columns = String(model.width);
  container.dataset.rows = String(model.height);
  const grid = ensureGridDom(container, model);
  for (const index of model.dirty) {
    const span = grid.cells[index];
    if (!span) continue;
    const x = index % model.width;
    const y = Math.floor(index / model.width);
    const style = model.styles.get(model.styleIds[index]);
    const cursorHere = Boolean(model.cursor && model.cursor.x === x && model.cursor.y === y);
    paintCell(span, x, y, style, model.chars[index], cursorHere);
  }
  model.dirty = new Set();
}

/**
 * Convenience wrapper for simple/synchronous callers (and tests): applies
 * `frame` to a model kept on `container` and immediately flushes it. The
 * live client uses `applyFrame`/`flushFrameModel` directly so it can defer
 * the DOM flush during a text selection without losing intermediate deltas.
 */
export function paintFrame(container, frame) {
  let model = container.__hydroniumInkModel;
  if (!model) { model = createFrameModel(); container.__hydroniumInkModel = model; }
  applyFrame(model, frame);
  flushFrameModel(container, model);
  return frame;
}

/**
 * Animation-tick pacing: a steady cadence (`baseDelayMs`, ~50-60ms) while the
 * story is actually animating, backing off toward `maxDelayMs` once a run of
 * consecutive idle ticks (an empty delta, no cursor/status change) shows
 * there is nothing moving. `noteActivity()` -- called on real user input, not
 * only on an animated tick -- snaps straight back to the base cadence, per
 * "resume on input/any change." Pure and DOM-free so it can be unit tested
 * on its own.
 */
export function createAnimationPacer({ baseDelayMs = 55, idleThreshold = 3, maxDelayMs = 2000, idleGrowth = 1.6 } = {}) {
  let idleStreak = 0;
  let delay = baseDelayMs;
  return {
    get delay() { return delay; },
    noteActivity() { idleStreak = 0; delay = baseDelayMs; },
    noteIdle() {
      idleStreak += 1;
      if (idleStreak >= idleThreshold) delay = Math.min(maxDelayMs, Math.round(delay * idleGrowth));
    },
  };
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
    zeros.className = "hydronium-lab__dimension-zero hydronium-ink-lab__dimension-zero";
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
  separator.className = "hydronium-lab__dimension-separator hydronium-ink-lab__dimension-separator";
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
 * Enhances the shared `hydronium_lab.workbench` DOM tree with Ink behavior.
 * `request(message)` is the only transport seam and may call an in-page Lua
 * runtime, `fetch`, a WebSocket RPC, or a Meteorite endpoint.
 */
export async function createInkLab({ root, request, autoResize = false, workbench = {}, animationIntervalMs = 55 }) {
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
  const canvasHud = query(root, "canvas-hud");
  if (canvasHud) {
    const colorControl = colorSelect?.closest("[data-lab-meta-control]");
    const sizeControl = sizeSelect?.closest("[data-lab-meta-control]");
    const canvasActions = query(canvasHud, "canvas-actions");
    if (colorControl) canvasHud.append(colorControl);
    if (sizeControl) canvasHud.append(sizeControl);
    if (dimensions) canvasHud.append(dimensions);
    if (canvasActions) canvasHud.append(canvasActions);
  }

  const projectKey = root.dataset.labProject || "hydronium-lab";
  const preferences = workbench.loadProjectPreferences
    ? await workbench.loadProjectPreferences(projectKey, { legacyDatabaseName: PREF_DB })
    : await preferencesFor(projectKey);
  const persist = (patch) => {
    Object.assign(preferences, patch);
    if (workbench.saveProjectPreferences) workbench.saveProjectPreferences(projectKey, preferences);
    else savePreferences(projectKey, preferences);
  };
  const workbenchPreferences = workbench.installWorkbenchPreferences?.({ root, preferences, persist });
  let catalog = await request({ op: "catalog" });
  let activeStory = catalog.stories.find((story) => story.id === preferences.story) || catalog.stories[0];
  let activeSize = activeStory.sizes[0];
  let fillMode = preferences.sizeMode === "fill";
  let closed = false;
  let paintedRect = null;
  let manualResizeRect = null;
  let manualResizeUntil = 0;
  let selectionGesture = false;
  const frameModel = createFrameModel();
  let pendingFlush = false;
  const pacer = createAnimationPacer({ baseDelayMs: animationIntervalMs });

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
    pacer.noteActivity();
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
      button.addEventListener("click", async () => { pacer.noteActivity(); paint(await request({ op: "interaction", name })); });
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
        const group = root.ownerDocument.createElement("section"); group.className = "hydronium-lab__story-group hydronium-ink-lab__story-group";
        const heading = root.ownerDocument.createElement("h2"); heading.textContent = name; group.append(heading);
        visibleStories.forEach((story) => { const button = root.ownerDocument.createElement("button"); button.type = "button"; button.className = "hydronium-lab__story hydronium-ink-lab__story"; button.textContent = story.title; button.setAttribute("aria-current", String(story.id === activeStory.id)); button.onclick = async () => { activeStory = story; persist({ story: story.id }); fillStories(); await open(); }; group.append(button); });
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

  // Trailing bookkeeping shared by a normal paint and a deferred flush: it
  // must run every time the DOM grid actually changes, whichever call site
  // triggered that.
  function afterFlush() {
    // While a browser drag is waiting for its debounced Ink resize, animation
    // frames still arrive. Preserve the user-owned CSS box across those old
    // frames instead of snapping it back to the previous `widthch × heightlh`.
    if (manualResizeRect) {
      terminal.style.width = `${manualResizeRect.width}px`;
      terminal.style.height = `${manualResizeRect.height}px`;
    }
    const rect = terminal.getBoundingClientRect();
    paintedRect = { width: rect.width, height: rect.height };
    renderDimensions(dimensions, frameModel.width, frameModel.height);
  }

  let lastPaintActivity = true;

  function resyncFrame() {
    if (closed) return;
    request({ op: "snapshot" }).then((full) => paint(full)).catch(() => {});
  }

  function paint(frame) {
    let result;
    try {
      result = applyFrame(frameModel, frame);
    } catch (error) {
      // A delta whose `base` doesn't match what this client last applied
      // (a dropped/reordered response, or the very rare recovery case) is
      // unsafe to paint. Self-heal with a full resync instead of showing a
      // corrupt grid; the transient tick that triggered this is otherwise
      // silently dropped, matching how a transient request failure is
      // already handled in `scheduleAnimation` below.
      if (error && error.desync) { lastPaintActivity = true; resyncFrame(); return frame; }
      throw error;
    }
    lastPaintActivity = result.activity;
    // Frame application always updates the logical model above, even during
    // a browser text selection -- only the DOM flush is deferred, so no
    // intermediate delta is ever lost, however many ticks arrive before the
    // user releases/clears their selection (see `flushDeferredFrame`).
    if (holdPaintForSelection()) {
      pendingFlush = true;
      return frame;
    }
    flushFrameModel(terminal, frameModel);
    pendingFlush = false;
    afterFlush();
    return frame;
  }

  function flushDeferredFrame() {
    if (!pendingFlush || holdPaintForSelection()) return;
    flushFrameModel(terminal, frameModel);
    pendingFlush = false;
    afterFlush();
  }

  async function open() {
    activeSize = activeStory.sizes[0];
    fillSizes();
    fillInteractions();
    if (colorSelect) colorSelect.value = preferences.color || activeStory.color;
    const target = fillMode ? fillTarget() : activeSize;
    activeSize = fillMode ? { name: "fill", ...target } : activeSize;
    pacer.noteActivity();
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
    pacer.noteActivity();
    paint(await request({ op: "resize", columns: activeSize.columns, rows: activeSize.rows }));
  });
  colorSelect?.addEventListener("change", async () => {
    persist({ color: colorSelect.value });
    pacer.noteActivity();
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
    pacer.noteActivity();
    paint(await request(keyboardEvent(event)));
  });
  terminal.addEventListener("paste", async (event) => {
    event.preventDefault();
    pacer.noteActivity();
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
  // Like `scheduleAnimation` below, at most one `op: "resize"` request may be
  // in flight at a time. `runtime.lua`'s `resize` op re-renders a full
  // cell-by-cell snapshot synchronously, so on a large canvas it can easily
  // outlast the 140ms debounce below: a slow drag then arms a second request
  // before the first settles. Two in-flight resizes race, and since `paint()`
  // renders whatever response lands, an older, slower response arriving after
  // a newer one used to snap the terminal back to a stale, smaller size right
  // as the user released the handle. Coalesce instead: while one is in
  // flight, newer targets only update `pendingResize`, and the in-flight
  // request's own completion re-arms it for whatever target is latest by
  // then, so at most one resize request is ever outstanding.
  let resizeBusy = false;
  let resizeGeneration = 0;
  async function runResize() {
    if (resizeBusy) return;
    const target = pendingResize;
    pendingResize = null;
    if (!target || closed || (target.columns === activeSize.columns && target.rows === activeSize.rows)) return;
    resizeBusy = true;
    const generation = ++resizeGeneration;
    activeSize = { name: "custom", columns: target.columns, rows: target.rows };
    pacer.noteActivity();
    try {
      const frame = await request({ op: "resize", columns: target.columns, rows: target.rows });
      if (!closed && generation === resizeGeneration) {
        manualResizeRect = null;
        paint(frame);
      }
    } finally {
      resizeBusy = false;
      if (pendingResize) runResize();
    }
  }
  function enableAutoResize() {
    if (!autoResize || typeof ResizeObserver === "undefined") return;
    terminal.style.resize = fillMode ? "none" : "both";
    terminal.style.overflow = "hidden";
    observer = new ResizeObserver(([entry]) => {
      // `flushFrameModel` itself sets width/height in `ch`/`lh`. Ignore the
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
      resizeTimer = window.setTimeout(runResize, 140);
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
  root.querySelectorAll("[data-lab-meta-control]").forEach((control) => control.addEventListener("click", (event) => {
    const select = control.querySelector("select");
    if (!select || event.target === select) return;
    event.preventDefault();
    if (typeof select.showPicker === "function") select.showPicker(); else { select.focus(); select.click(); }
  }));
  // `setInterval` used to enqueue another `step` every 160-900ms (throttled
  // by canvas size, to hide a full per-cell JSON payload's own encode cost)
  // even if a previous tick was still encoding, painting, or waiting behind
  // a resize -- an unbounded serialized-request backlog, and a floor on
  // animation smoothness that grew with the canvas. Frame protocol v2's
  // delta encoding (see hydronium_ink_lab.frame) made an idle or
  // small-change tick cheap regardless of canvas size, so the size-based
  // throttle is gone: `scheduleAnimation` now runs at one steady cadence
  // (`pacer`, default ~55ms, configurable via `animationIntervalMs`),
  // scheduling the next tick only after the previous one settles (still no
  // backlog), and backs off toward `pacer`'s ceiling once a run of
  // genuinely idle deltas (see `applyFrame`'s `activity` result) shows nothing
  // is animating -- `pacer.noteActivity()` at every real input/interaction
  // site above snaps it back to full cadence immediately.
  let animationTimer = null;
  const scheduleAnimation = () => {
    window.clearTimeout(animationTimer);
    animationTimer = window.setTimeout(async () => {
      if (closed) return;
      if (!document.hidden) {
        try {
          paint(await request({ op: "step", nowMs: performance.now() }));
          if (lastPaintActivity) pacer.noteActivity(); else pacer.noteIdle();
        } catch (_) {
          // The transport's visible status surface reports real failures. A
          // transient animation tick must not unmount the last good frame.
        }
      }
      if (!closed) scheduleAnimation();
    }, pacer.delay);
  };
  scheduleAnimation();
  return {
    catalog,
    terminal,
    resize: async (columns, rows) => { pacer.noteActivity(); return paint(await request({ op: "resize", columns, rows })); },
    input: async (input, key = {}) => { pacer.noteActivity(); return paint(await request({ op: "input", input, key })); },
    paste: async (text) => { pacer.noteActivity(); return paint(await request({ op: "paste", text })); },
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
      pacer.noteActivity();
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
      workbenchPreferences?.destroy();
      return request({ op: "close" });
    },
  };
}
