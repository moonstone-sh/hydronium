import { createInkLab } from "./virtual_terminal.js";

const root = document.querySelector("[data-hydronium-ink-lab]");
const status = root?.querySelector("[data-lab-status]");
let session = null;
let sequence = 0;
let generation = null;
let instance = null;
let lab = null;
let operationTail = Promise.resolve();

async function json(url, options = {}) {
  const response = await fetch(url, { cache: "no-store", ...options });
  const body = await response.text();
  let value;
  try {
    value = JSON.parse(body);
  } catch (_) {
    throw new Error(`HTTP ${response.status}: ${body.slice(0, 160) || "invalid JSON response"}`);
  }
  if (!response.ok || value.ok === false) throw Object.assign(new Error(value.message || value.outcome || `HTTP ${response.status}`), { outcome: value.outcome });
  return value;
}

async function ensureSession() {
  if (session) return;
  const value = await json("/__hydronium/lab/sessions", {
    method: "POST", headers: { "content-type": "application/json", "x-hydronium-lab": "1" }, body: "{}",
  });
  session = value.session;
  generation = value.generation;
  sequence = 0;
}

async function performRequest(message) {
  if (message.op === "catalog") {
    const value = await json("/__hydronium/lab/catalog");
    return value.catalog;
  }
  await ensureSession();
  sequence += 1;
  try {
    const value = await json(`/__hydronium/lab/sessions/${encodeURIComponent(session)}/operations`, {
      method: "POST", headers: { "content-type": "application/json", "x-hydronium-lab": "1" },
      body: JSON.stringify({ sequence, generation, request: message }),
    });
    return value.result;
  } catch (error) {
    if (error.outcome === "session_expired" || error.outcome === "stale_revision") {
      session = null;
      await ensureSession();
      sequence += 1;
      const value = await json(`/__hydronium/lab/sessions/${encodeURIComponent(session)}/operations`, {
        method: "POST", headers: { "content-type": "application/json", "x-hydronium-lab": "1" },
        body: JSON.stringify({ sequence, generation, request: message }),
      });
      return value.result;
    }
    throw error;
  }
}

// Session operations carry a monotonic sequence. Browser input, ResizeObserver
// callbacks, and a story change may all happen in the same tick, so serialize
// them here instead of allowing fetch completion order to corrupt the session.
function request(message) {
  if (message.op === "catalog") return performRequest(message);
  const next = operationTail.then(() => performRequest(message));
  operationTail = next.catch(() => undefined);
  return next;
}

try {
  lab = await createInkLab({ root, request, autoResize: true });
  if (status) status.textContent = "Connected";
} catch (error) {
  if (status) status.textContent = `Error: ${error.message}`;
}

// The Lab has no WebSocket dependency. Polling a tiny, no-store catalog is
// sufficient for a local workbench and keeps HTTP request/response ordering
// explicit. The server publishes a new generation only after it has built a
// complete valid registry; therefore an authoring error leaves the last frame
// in place rather than replacing it with a partial catalog.
async function refreshCatalog() {
  if (!lab || document.hidden) return;
  try {
    const value = await json("/__hydronium/lab/catalog");
    if (value.error) {
      if (status) status.textContent = `Update failed — showing last preview: ${value.error}`;
      return;
    }
    if (generation === null) generation = value.generation;
    const serverChanged = instance !== null && value.instance !== instance;
    if (instance === null) instance = value.instance;
    if (!serverChanged && value.generation === generation) return;
    if (status) status.textContent = "Updating preview…";
    await lab.refresh(value.catalog);
    generation = value.generation;
    instance = value.instance;
    if (status) status.textContent = "Updated";
  } catch (error) {
    // Keep the existing terminal frame visible. A subsequent successful
    // catalog response performs the refresh atomically.
    if (status) status.textContent = `Update failed — showing last preview: ${error.message}`;
  }
}

const refreshTimer = window.setInterval(refreshCatalog, 750);
window.addEventListener("pagehide", () => window.clearInterval(refreshTimer), { once: true });
