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
