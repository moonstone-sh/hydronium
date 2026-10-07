// Gate for the browser build: boots dist/ in Node and checks that LuaLS with
// Hydronium's plugin diagnoses, completes and hovers a .luax file the way
// native lua-language-server does. Skips (exit 0) when dist/ is not built.
import { readFileSync, existsSync } from "node:fs";
const here = new URL(".", import.meta.url).pathname;
if (!existsSync(here + "dist/luals.wasm")) { console.log("luals-web: dist/ not built (./build.sh); skipped"); process.exit(0); }
const { default: createModule } = await import("./dist/luals.mjs");
const APP = `---@param props { label: string }
local function App(props)
  return (
    <d.div class="app">
      <d.button disabled={"yes"} onClick={function() end}>{props.label}</d.button>
    </d.div>
  )
end

return App
`;
const outbox = [];
const t0 = performance.now();
const M = await createModule({
  onLualsEmit(kind, text) { if (kind === 1) outbox.push(JSON.parse(text)); else if (/^(error|warn)/.test(text)) console.error("[luals]", text.slice(0, 200)); },
  locateFile: (f) => here + "dist/" + f,
});
const enc = new TextEncoder();
const bytes = (v) => (typeof v === "string" ? enc.encode(v) : v);
const withBuf = (data, fn) => { const b = bytes(data); const p = M._malloc(b.length + 1); M.HEAPU8.set(b, p); try { return fn(p, b.length); } finally { M._free(p); } };
const result = () => M.UTF8ToString(M._luals_result(), M._luals_result_len());
const run = (code, name) => withBuf(code, (p, n) => withBuf(name + "\0", (np) => { if (M._luals_run(p, n, np) !== 0) throw new Error(result()); }));
const invoke = (fn, data) => withBuf(fn + "\0", (fp) => data == null
  ? (M._luals_invoke(fp, 0, 0) === 0 ? result() : (() => { throw new Error(result()); })())
  : withBuf(data, (p, n) => (M._luals_invoke(fp, p, n) === 0 ? result() : (() => { throw new Error(result()); })())));

if (M._luals_init() !== 0) throw new Error("init");
run(readFileSync(here + "dist/shim.lua"), "@/luals/shim.lua");
console.log("mounted", invoke("mount", readFileSync(here + "dist/luals-bundle.bin")), "files");
invoke("write", "/workspace/App.luax\0" + APP);
invoke("boot");
console.log(`booted in ${(performance.now() - t0).toFixed(0)} ms (engine + bundle + LuaLS)`);

const settings = {
  Lua: {
    runtime: { version: "LuaJIT", path: ["?.lua", "?/init.lua", "?.luax", "?/init.luax"], plugin: "/hydronium/luax/src/hydronium_luax/luals/init.lua" },
    workspace: { library: ["/hydronium/types/core", "/hydronium/types/luax", "/hydronium/types/dom"], checkThirdParty: false },
    diagnostics: { globals: ["__luax", "__luax_component", "__luax_fragment"] },
  },
  "files.associations": { "*.luax": "lua" },
};
let id = 0;
const responses = new Map();
const diagnostics = new Map();
const send = (msg) => invoke("receive", JSON.stringify({ jsonrpc: "2.0", ...msg }));
const request = (method, params) => { send({ id: ++id, method, params }); return id; };
const notify = (method, params) => send({ method, params });
const drain = () => {
  while (outbox.length) {
    const m = outbox.shift();
    if (m.method && m.id != null) send({ id: m.id, result: m.method === "workspace/configuration" ? m.params.items.map((i) => settings[i.section] ?? null) : null });
    else if (m.id != null) responses.set(m.id, m);
    else if (m.method === "textDocument/publishDiagnostics") diagnostics.set(m.params.uri, m.params.diagnostics);
  }
};
const pump = async (done, ms = 15000) => {
  const end = performance.now() + ms;
  while (performance.now() < end) {
    invoke("step");
    drain();
    if (done()) return true;
    await new Promise((r) => setTimeout(r, 1));
  }
  return false;
};

let t = performance.now();
const init = request("initialize", { processId: null, rootUri: "file:///workspace", workspaceFolders: [{ uri: "file:///workspace", name: "workspace" }],
  capabilities: { workspace: { configuration: true }, textDocument: { completion: { completionItem: { snippetSupport: true } }, hover: { contentFormat: ["markdown"] } } },
  initializationOptions: { trustByClient: true } });
await pump(() => responses.has(init));
notify("initialized", {});
const uri = "file:///workspace/App.luax";
notify("textDocument/didOpen", { textDocument: { uri, languageId: "lua", version: 1, text: APP } });
t = performance.now();
await pump(() => (diagnostics.get(uri) || []).some((d) => d.code === "assign-type-mismatch"));
console.log(`diagnostics after ${(performance.now() - t).toFixed(0)} ms:`);
for (const d of diagnostics.get(uri) || []) console.log(`  ${d.range.start.line + 1}:${d.range.start.character + 1} ${d.code} ${d.message.split("\n")[0]}`);
const curi = "file:///workspace/Complete.luax";
notify("textDocument/didOpen", { textDocument: { uri: curi, languageId: "lua", version: 1, text: "return <d.\n" } });
t = performance.now();
const cid = request("textDocument/completion", { textDocument: { uri: curi }, position: { line: 0, character: 10 }, context: { triggerKind: 2, triggerCharacter: "." } });
await pump(() => responses.has(cid));
const items = responses.get(cid)?.result?.items ?? responses.get(cid)?.result ?? [];
console.log(`completion: ${items.length} items in ${(performance.now() - t).toFixed(0)} ms: ${items.slice(0, 10).map((i) => i.label).join(" ")}`);
t = performance.now();
const hid = request("textDocument/hover", { textDocument: { uri }, position: { line: 4, character: 10 } });
await pump(() => responses.has(hid));
console.log(`hover in ${(performance.now() - t).toFixed(0)} ms: ${responses.get(hid)?.result?.contents?.value?.split("\n").slice(0, 2).join(" ").slice(0, 140)}`);
console.log(`wasm memory: ${(M.HEAPU8.length / 1048576).toFixed(0)} MB`);

const fails = [];
if (!(diagnostics.get(uri) || []).some((d) => d.code === "assign-type-mismatch" && d.range.start.line === 4 && d.range.start.character === 16)) fails.push("diagnostic at 5:17");
if (!items.some((i) => i.label === "button") || items.length < 100) fails.push("<d. completion");
if (!/HTMLButtonProps/.test(responses.get(hid)?.result?.contents?.value || "")) fails.push("hover");
if (fails.length) { console.error("FAIL: " + fails.join(", ")); process.exit(1); }
console.log("PASS luals-web");
