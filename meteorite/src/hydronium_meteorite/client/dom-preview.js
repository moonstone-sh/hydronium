// Machado, Oliveira & Fernandes (2009), severity 1.0, applied in linear RGB.
// https://www.inf.ufrgs.br/~oliveira/pubs_files/CVD_Simulation/CVD_Simulation.html
// These are approximations for inspection, not an accessibility conformance test.
const VISION_MATRICES = {
  protanopia: [.152286,1.052583,-.204868,.114503,.786281,.099216,-.003882,-.048116,1.051998],
  deuteranopia: [.367322,.860646,-.227968,.280085,.672501,.047413,-.011820,.042940,.968881],
  tritanopia: [1.255528,-.076749,-.178779,-.078411,.930809,.147602,.004733,.691367,.303900],
  achromatopsia: [.2126,.7152,.0722,.2126,.7152,.0722,.2126,.7152,.0722],
};
function installVisionFilters() {
  const ns='http://www.w3.org/2000/svg',svg=document.createElementNS(ns,'svg');
  svg.setAttribute('width','0');svg.setAttribute('height','0');svg.style.position='absolute';svg.setAttribute('aria-hidden','true');
  const defs=document.createElementNS(ns,'defs');svg.append(defs);
  for(const [name,matrix] of Object.entries(VISION_MATRICES)){
    const filter=document.createElementNS(ns,'filter');filter.id='lab-vision-'+name;filter.setAttribute('color-interpolation-filters','linearRGB');
    const node=document.createElementNS(ns,'feColorMatrix');node.setAttribute('type','matrix');
    node.setAttribute('values',`${matrix.slice(0,3).join(' ')} 0 0 ${matrix.slice(3,6).join(' ')} 0 0 ${matrix.slice(6,9).join(' ')} 0 0 0 0 0 1 0`);filter.append(node);defs.append(filter);
  }
  document.body.prepend(svg);
}
import { mount } from "./dom-client/mount.js";
function literal(value) {
  if (value === null || value === undefined) return "nil";
  if (typeof value === "string") return '"' + value.replace(/[\\"\x00-\x1f]/g, char => char === '"' ? '\\"' : char === '\\' ? '\\\\' : "\\" + char.charCodeAt(0).toString().padStart(3, "0")) + '"';
  if (typeof value === "number") { if (!Number.isFinite(value)) throw new Error("Expected finite value"); return String(value); }
  if (typeof value === "boolean") return String(value);
  if (Array.isArray(value)) return "{" + value.map(literal).join(",") + "}";
  return "{" + Object.entries(value).map(([key, item]) => `[${literal(key)}]=${literal(item)}`).join(",") + "}";
}
try {
  const base = document.body.dataset.labBasePath;
  const story = new URL(location.href).searchParams.get("story");
  const metadata = await (await fetch(base + "/dom/modules")).json();
  const moduleEffects = Object.fromEntries(Object.keys(metadata.modules).map(id => [id, "safe"]));
  moduleEffects["hydronium_lab.dom_entry"] = "safe";
  moduleEffects["hydronium_lab.dom_preview"] = "safe";
  const handle = await mount({ moduleEffects, chunkUrls: [base + "/dom/bundle"], appModuleId: "hydronium_lab.dom_entry", container: "#preview", props: { story }, hmr: true });
  // One Lua call at a time: overlapping async doString calls into the same
  // wasm VM corrupt its state (seen as `require` failing with "attempt to
  // index a nil value"). xpcall keeps the original Lua stack: a bare doString
  // error only shows the require wrapper that rethrew it.
  let invokeTail = Promise.resolve();
  const invoke = (method, message) => {
    const call = invokeTail.then(() => handle.lua.doString(`local ok, result = xpcall(function() return require("hydronium_lab.dom_preview").${method}(${message === undefined ? "" : literal(message)}) end, debug.traceback) if not ok then error(result, 0) end return result`));
    invokeTail = call.catch(() => {});
    return call;
  };
  installVisionFilters();
  window.hydroniumLabPreview = {
    async configure(settings) {
      const { colorSpace = "srgb", vision = "none", width = 800, height = 600 } = settings;
      if (!["srgb", "display-p3", "rec2020"].includes(colorSpace) || (vision !== "none" && !VISION_MATRICES[vision])) throw new Error("Invalid DOM preview environment");
      document.documentElement.dataset.labColorSpace = colorSpace;
      document.documentElement.dataset.labVision = vision;
      document.documentElement.style.setProperty("--lab-color-space", colorSpace);
      document.querySelector("#preview").style.filter = vision === "none" ? "" : `url(#lab-vision-${vision})`;
      await invoke("request", { op: "environment", environment: { colorSpace, vision, width, height } });
    },
    request: message => invoke("request", message),
    snapshot: () => invoke("request", { op: "snapshot" }),
    reloadStyles() { for (const link of document.querySelectorAll('link[rel="stylesheet"]')) { const url = new URL(link.href); url.searchParams.set("revision", Date.now()); link.href = url.href; } },
    async replace(sources) {
      const summary = await handle.lua.doString(`return require("hydronium.core.hmr").apply_batch(${literal(sources)}, {effects= ${literal(Object.fromEntries(Object.keys(sources).map(id => [id, "safe"])))} })`);
      if (summary.failed || summary.outcome === "rejected" || summary.outcome === "restart") throw new Error(summary.reason || "Hot update failed");
      await invoke("refresh");
    },
  };
  // Close the VM only after the unmount's queued work has run: closing it in
  // the same task left those callbacks touching freed wasm memory
  // ("memory access out of bounds") in a retired preview.
  window.addEventListener("pagehide", () => {
    Promise.resolve(handle.lua.doString('if __hydronium_tree then __hydronium_reconciler:unmount(__hydronium_tree) end'))
      .catch(() => {})
      .finally(() => setTimeout(() => { try { handle.lua.global.close(); } catch {} }, 0));
  }, { once: true });
  parent.postMessage({ type: "hydronium-lab-preview-ready" }, location.origin);
} catch (error) { parent.postMessage({ type: "hydronium-lab-preview-ready", error: error.message }, location.origin); }
