/**
 * Hydronium dev error overlay.
 *
 * WHY THIS EXISTS. A Lua error in the browser surfaces as a JS Error whose
 * message is a Lua traceback produced inside a WASM VM. Until now the only
 * place it appeared was the console, which means the page looks merely blank
 * or stale and the developer has to know to go looking. Every comparable
 * framework puts the error on the page. This does that.
 *
 * DEV ONLY, BY CONSTRUCTION. Nothing here runs unless a host explicitly calls
 * `installErrorOverlay()`. There is no auto-install on import, no global hook
 * registered as a side effect, and no environment sniffing that could guess
 * wrong in production. A production bundle that never calls it pays only for
 * the bytes.
 *
 * WHAT IT SHOWS. The message, then the Lua frames parsed out of the traceback
 * (module id and line), then the raw traceback verbatim. The raw text is kept
 * because the parser below is deliberately conservative: a frame shape it does
 * not recognize must still be readable, not swallowed.
 *
 * SOURCE MAPS. `hydronium_luax.compile` emits a real Source Map v3 per `.luax`
 * file (`map_json`), but nothing serves it to the browser yet, so there is
 * nothing to resolve against here. Rather than half-build that, this module
 * takes an optional `resolveFrame` hook: give it a function and the overlay
 * renders the resolved `.luax` file/line instead of the generated Lua line.
 * Wiring a map-serving route later needs no change to this file.
 */

const OVERLAY_ID = "__hydronium_error_overlay__";

/**
 * Lua tracebacks name chunks as `[string "<chunkname>"]:<line>:` — and
 * `mount.js` loads every module with `load(src, "@" .. module_id)`, so the
 * chunkname IS the module id. That is what makes a frame addressable.
 * Also matches the `@id` form some Lua builds print.
 */
const FRAME_RE = /\[string "([^"]+)"\]:(\d+)|(?:^|\s)@?([\w./-]+\.lua[x]?):(\d+)/g;

/** @returns {{ module: string, line: number }[]} */
export function parseLuaFrames(text) {
  if (typeof text !== "string" || text === "") return [];
  const frames = [];
  const seen = new Set();
  FRAME_RE.lastIndex = 0;
  let m;
  while ((m = FRAME_RE.exec(text)) !== null) {
    const module = m[1] ?? m[3];
    const line = Number(m[2] ?? m[4]);
    if (!module || !Number.isFinite(line)) continue;
    const key = `${module}:${line}`;
    // A Lua traceback repeats the erroring frame in its header and again in
    // the stack; show it once.
    if (seen.has(key)) continue;
    seen.add(key);
    frames.push({ module, line });
  }
  return frames;
}

/**
 * The first line of a Lua error is usually `chunk:line: message`. Strip that
 * prefix for the headline — the location is already shown as a frame — but
 * only when it really is that shape, never by blindly cutting at a colon.
 */
export function errorHeadline(text) {
  if (typeof text !== "string") return String(text);
  const first = text.split("\n", 1)[0];
  const stripped = first.replace(/^\[string "[^"]+"\]:\d+:\s*/, "");
  return stripped === "" ? first : stripped;
}

function el(doc, tag, style, text) {
  const node = doc.createElement(tag);
  if (style) node.setAttribute("style", style);
  if (text !== undefined) node.textContent = text;
  return node;
}

const S = {
  root:
    "position:fixed;inset:0;z-index:2147483647;overflow:auto;" +
    "background:rgba(9,10,13,.94);color:#e6e6e6;" +
    "font:13px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;padding:32px",
  card: "max-width:900px;margin:0 auto;background:#14161b;border:1px solid #33373f;border-radius:8px;overflow:hidden",
  bar: "display:flex;align-items:center;justify-content:space-between;gap:12px;padding:12px 16px;background:#7f1d1d;color:#fff",
  title: "font-weight:700;letter-spacing:.02em",
  close:
    "appearance:none;border:1px solid rgba(255,255,255,.4);background:transparent;color:#fff;" +
    "border-radius:4px;padding:2px 10px;cursor:pointer;font:inherit",
  body: "padding:16px",
  msg: "margin:0 0 14px;white-space:pre-wrap;word-break:break-word;color:#ffb4b4;font-size:14px",
  h: "margin:0 0 6px;color:#9aa4b2;text-transform:uppercase;font-size:11px;letter-spacing:.08em",
  frame: "padding:3px 0;color:#cfd6e4",
  mod: "color:#7dd3fc",
  raw: "margin:0;padding:12px;background:#0d0f13;border:1px solid #2a2e36;border-radius:6px;white-space:pre-wrap;word-break:break-word;color:#98a2b3;max-height:40vh;overflow:auto",
};

/**
 * Renders (or replaces) the overlay. Exported for tests so the DOM can be
 * asserted without booting a Lua VM.
 * @param {Document} doc
 * @param {{ phase?: string, error: unknown, resolveFrame?: (f: {module:string,line:number}) => ({file:string,line:number}|null) }} info
 */
export function renderErrorOverlay(doc, info) {
  const existing = doc.getElementById(OVERLAY_ID);
  if (existing) existing.remove();

  const err = info && info.error;
  const text =
    err && typeof err === "object" && "stack" in err && err.stack
      ? String(err.stack)
      : String((err && err.message) || err);

  const root = el(doc, "div", S.root);
  root.id = OVERLAY_ID;
  root.setAttribute("role", "alert");

  const card = el(doc, "div", S.card);
  const bar = el(doc, "div", S.bar);
  bar.append(
    el(doc, "span", S.title, info && info.phase ? `Hydronium — ${info.phase}` : "Hydronium error")
  );
  const close = el(doc, "button", S.close, "Dismiss");
  close.setAttribute("type", "button");
  close.addEventListener("click", () => root.remove());
  bar.append(close);
  card.append(bar);

  const body = el(doc, "div", S.body);
  body.append(el(doc, "p", S.msg, errorHeadline(text)));

  const frames = parseLuaFrames(text);
  if (frames.length > 0) {
    body.append(el(doc, "div", S.h, "Lua frames"));
    for (const f of frames) {
      const resolved =
        typeof info.resolveFrame === "function" ? info.resolveFrame(f) : null;
      const row = el(doc, "div", S.frame);
      const where = el(doc, "span", S.mod, resolved ? resolved.file : f.module);
      row.append(where, doc.createTextNode(`:${resolved ? resolved.line : f.line}`));
      // Say so when a frame is the generated Lua rather than the .luax the
      // developer wrote, instead of quietly implying it is their source.
      if (!resolved) row.append(doc.createTextNode("  (generated Lua)"));
      body.append(row);
    }
  }

  body.append(el(doc, "div", `${S.h};margin-top:14px`, "Traceback"));
  body.append(el(doc, "pre", S.raw, text));

  card.append(body);
  root.append(card);
  doc.body.appendChild(root);
  return root;
}

export function dismissErrorOverlay(doc) {
  const node = (doc || document).getElementById(OVERLAY_ID);
  if (node) node.remove();
  return Boolean(node);
}

/**
 * Installs the overlay and returns a `report(phase, error)` function plus an
 * `uninstall()`. Explicit by design — see this module's header.
 *
 * `captureGlobal` additionally routes uncaught errors and unhandled rejections
 * to the overlay. Off by default: a host that already funnels its own failures
 * (mount, HMR) may not want every unrelated page error taking over the screen.
 */
export function installErrorOverlay(options = {}) {
  const doc = options.document || document;
  const resolveFrame = options.resolveFrame;
  const report = (phase, error) =>
    renderErrorOverlay(doc, { phase, error, resolveFrame });

  let detach = null;
  if (options.captureGlobal) {
    const onError = (ev) => report("uncaught error", ev.error || ev.message);
    const onRejection = (ev) => report("unhandled rejection", ev.reason);
    const w = options.window || window;
    w.addEventListener("error", onError);
    w.addEventListener("unhandledrejection", onRejection);
    detach = () => {
      w.removeEventListener("error", onError);
      w.removeEventListener("unhandledrejection", onRejection);
    };
  }

  return {
    report,
    dismiss: () => dismissErrorOverlay(doc),
    uninstall() {
      if (detach) detach();
      dismissErrorOverlay(doc);
    },
  };
}
