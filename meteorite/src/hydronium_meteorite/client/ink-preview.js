import { createInkLab } from "./virtual_terminal.js";
import * as workbench from "./workbench.js";

const root = document.querySelector("[data-hydronium-ink-lab]");
const status = root?.querySelector("[data-lab-status]");
const basePath = (root?.dataset.labBasePath || "/__hydronium/lab").replace(/\/+$/, "") || "/";
const labUrl = (suffix) => `${basePath === "/" ? "" : basePath}/${suffix}`;
const transport = {
  catalog: root?.dataset.labCatalogUrl || labUrl("catalog"),
  createSession: root?.dataset.labCreateSessionUrl || labUrl("sessions"),
  sessionOperations: root?.dataset.labSessionOperationsUrl || labUrl("sessions/{id}/operations"),
  closeSession: root?.dataset.labCloseSessionUrl || labUrl("sessions/{id}"),
};
const sessionUrl = (template, id) => template.replace("{id}", encodeURIComponent(id));
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

// Sessions run on this server over HTTP, or wherever the host's transport
// module puts them (data-lab-ink-transport, e.g. a browser worker). A module
// exports createInkTransport({ basePath, catalogUrl }) returning
// { createSession(), operation(session, envelope), close(session) } with the
// HTTP endpoints' JSON shapes.
const httpSessions = {
  createSession: () => json(transport.createSession, {
    method: "POST", headers: { "content-type": "application/json", "x-hydronium-lab": "1" }, body: "{}",
  }),
  operation: (id, envelope) => json(sessionUrl(transport.sessionOperations, id), {
    method: "POST", headers: { "content-type": "application/json", "x-hydronium-lab": "1" },
    body: JSON.stringify(envelope),
  }),
  close: (id) => fetch(sessionUrl(transport.closeSession, id), {
    method: "DELETE", headers: { "x-hydronium-lab": "1" }, keepalive: true,
  }).catch(() => undefined),
};
function checked(value) {
  if (!value || value.ok === false) throw Object.assign(new Error(value?.message || value?.outcome || "Ink session failed"), { outcome: value?.outcome });
  return value;
}
let sessionsPromise = null;
function sessions() {
  const url = root?.dataset.labInkTransport;
  if (!url) return Promise.resolve(httpSessions);
  sessionsPromise ??= import(new URL(url, location.href).href).then(async module => {
    const custom = await module.createInkTransport({ basePath, catalogUrl: transport.catalog });
    return {
      createSession: async () => checked(await custom.createSession()),
      operation: async (id, envelope) => checked(await custom.operation(id, envelope)),
      close: async (id) => custom.close(id),
    };
  });
  return sessionsPromise;
}

async function ensureSession() {
  if (session) return;
  const value = await (await sessions()).createSession();
  session = value.session;
  generation = value.generation;
  sequence = 0;
}

async function performRequest(message) {
  if (message.op === "catalog") {
    const value = await json(transport.catalog);
    return { stories: value.catalog.stories.filter(story => story.renderer === "ink") };
  }
  await ensureSession();
  sequence += 1;
  const backend = await sessions();
  try {
    const value = await backend.operation(session, { sequence, generation, request: message });
    return value.result;
  } catch (error) {
    if (error.outcome === "session_expired" || error.outcome === "stale_revision") {
      session = null;
      await ensureSession();
      sequence += 1;
      const value = await backend.operation(session, { sequence, generation, request: message });
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
  lab = await createInkLab({ root, request, autoResize: false, workbench, initialStoryId: new URL(location.href).searchParams.get("story") });
  await lab.flushed();
  const snapshot = () => { const state = lab.state.getSnapshot(); return { lab: { args: state.args, playback: state.playback } }; };
  window.hydroniumLabPreview = { snapshot, async configure(settings) { if (settings.columns && settings.rows) await lab.resize(settings.columns, settings.rows); if (settings.color) await lab.setColor(settings.color); await lab.flushed(); const screen = lab.terminal.querySelector(".xterm-screen"); return {width: screen?.offsetWidth, height: screen?.offsetHeight}; }, async request(message) {
    if (message.op === "open") { await lab.selectStory(message.story); return snapshot(); }
    if (message.op === "args") return lab.setArgs(message.args);
    if (message.op === "resetArgs") return lab.state.resetArgs();
    if (message.op === "restart") return lab.restart();
    if (message.op === "advance") return lab.advance();
    if (message.op === "seek") return lab.seek(message.nowMs);
    if (message.op === "playback") { if (message.intervalMs) await lab.state.setInterval(message.intervalMs); if (message.playing !== undefined) await (message.playing ? lab.play() : lab.pause()); return snapshot(); }
    return snapshot();
  } };
  // Keep the Lab's timeline (time, frame, play state) in step with this
  // preview's virtual playback, about ten times a second.
  let pendingState = null;
  lab.state.subscribe(() => {
    if (pendingState) return;
    pendingState = setTimeout(() => { pendingState = null; parent.postMessage({ type: "hydronium-lab-preview-state", ...snapshot() }, location.origin); }, 100);
  });
  parent.postMessage({ type: "hydronium-lab-preview-ready" }, location.origin);
  if (status) status.textContent = "Connected";
} catch (error) {
  parent.postMessage({ type: "hydronium-lab-preview-ready", error: error.message }, location.origin);
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
    const value = await json(transport.catalog);
    if (value.error) {
      if (status) status.textContent = `Update failed — showing last preview: ${value.error}`;
      return;
    }
    if (generation === null) generation = value.generation;
    const serverChanged = instance !== null && value.instance !== instance;
    if (instance === null) instance = value.instance;
    if (!serverChanged && value.generation === generation) return;
    if (status) status.textContent = "Updating preview…";
    await lab.refresh({stories:value.catalog.stories.filter(story=>story.renderer==="ink")});
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
window.addEventListener("pagehide", () => {
  window.clearInterval(refreshTimer);
  lab?.close();
  if (!session) return;
  const id = session;
  session = null;
  sessions().then(backend => backend.close(id)).catch(() => undefined);
}, { once: true });
