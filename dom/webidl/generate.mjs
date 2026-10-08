#!/usr/bin/env node
// LuaCATS for WebGL 1/2 and WebGPU, generated from the specifications' WebIDL
// (dom/webidl/idl, vendored from @webref/idl; see idl/SOURCE.md).
//
//   node dom/webidl/generate.mjs          writes dom/types/dom/webgl.d.lua and webgpu.d.lua
//   node dom/webidl/generate.mjs --check  exits 1 when either file is stale
//
// The objects these types describe are host references (lua-wasm Bridge API 2,
// lua-wasm/docs/value-semantics.md), which fixes the mapping:
// - interfaces become classes; methods take `self` (call them with `:`);
//   constants and attributes are fields; mixins (`includes`) are parents.
// - a method returning Promise<T> returns T: the host call suspends the Lua
//   task until the promise settles. An attribute holding a promise is not
//   awaited, so it is typed HostPromise.
// - dictionaries are table shapes (a Lua table crosses as a JS object; a
//   sequence as an Array); enums are string unions.
// - typed arrays and ArrayBuffers come from typed_arrays.d.lua; names the
//   IDL references but Hydronium does not type become `any`.
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const typesDir = join(here, "../types/dom");
const OUTPUTS = [
  { file: "webgl.d.lua", idl: ["webgl1.idl", "webgl2.idl"], title: "WebGL 1.0 and 2.0",
    note: "Get a context with `canvas.context(ref, \"webgl2\")` (hydronium_dom.canvas). Buffers take typed arrays: `canvas.typed(\"Float32Array\", { ... })`." },
  { file: "webgpu.d.lua", idl: ["webgpu.idl"], title: "WebGPU",
    note: "Start from `canvas.webgpu()` (hydronium_dom.canvas): `gpu`, the usage flags, and `canvas.context(ref, \"webgpu\")`. Descriptors are ordinary Lua tables. `end` is a Lua keyword: call `pass[\"end\"](pass)`." },
];

// ---------------------------------------------------------------- tokenizer
function tokenize(text) {
  text = text.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/\/\/[^\n]*/g, " ");
  const tokens = [];
  const re = /\s+|("(?:[^"\\]|\\.)*")|(-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?|Infinity)|-Infinity|NaN)|(\.\.\.)|([A-Za-z_][\w-]*)|([{}()\[\]<>;:,=?*])/y;
  let match;
  while (re.lastIndex < text.length) {
    const at = re.lastIndex;
    match = re.exec(text);
    if (!match) throw new Error(`WebIDL: unexpected character at ${at}: ${JSON.stringify(text.slice(at, at + 20))}`);
    if (match[1]) tokens.push({ kind: "string", value: JSON.parse(match[1]) });
    else if (match[2]) tokens.push({ kind: "number", value: match[2] });
    else if (match[3]) tokens.push({ kind: "punct", value: "..." });
    else if (match[4]) tokens.push({ kind: "ident", value: match[4] });
    else if (match[5]) tokens.push({ kind: "punct", value: match[5] });
  }
  return tokens;
}

// ------------------------------------------------------------------- parser
function parse(text) {
  const t = tokenize(text);
  let i = 0;
  const peek = (o = 0) => t[i + o];
  const is = (value, o = 0) => t[i + o] && t[i + o].value === value;
  const next = () => t[i++];
  const expect = (value) => {
    const token = next();
    if (!token || token.value !== value) throw new Error(`WebIDL: expected ${value}, got ${token && token.value} (token ${i})`);
    return token;
  };
  const ident = () => {
    const token = next();
    if (!token || token.kind !== "ident") throw new Error(`WebIDL: expected a name, got ${token && token.value}`);
    return token.value.replace(/^_/, "");
  };
  function skipExtAttrs() {
    while (is("[")) {
      let depth = 0;
      do {
        const token = next();
        if (token.value === "[" || token.value === "(") depth++;
        if (token.value === "]" || token.value === ")") depth--;
      } while (depth > 0);
    }
  }
  const PRIMITIVE_WORDS = new Set(["unsigned", "unrestricted", "long", "short", "float", "double", "byte", "octet", "boolean", "any", "object", "undefined", "void", "bigint", "symbol"]);
  function type() {
    skipExtAttrs();
    let node;
    if (is("(")) {
      next();
      const items = [type()];
      while (is("or")) { next(); items.push(type()); }
      expect(")");
      node = { kind: "union", items };
    } else {
      const first = ident();
      if (["sequence", "FrozenArray", "ObservableArray", "Promise"].includes(first)) {
        expect("<"); const arg = type(); expect(">");
        node = { kind: "generic", name: first, args: [arg] };
      } else if (first === "record") {
        expect("<"); const key = type(); expect(","); const value = type(); expect(">");
        node = { kind: "generic", name: "record", args: [key, value] };
      } else {
        const words = [first];
        while (PRIMITIVE_WORDS.has(first) && peek() && PRIMITIVE_WORDS.has(peek().value) && peek().kind === "ident") words.push(ident());
        node = { kind: "name", name: words.join(" ") };
      }
    }
    if (is("?")) { next(); node.nullable = true; }
    return node;
  }
  function defaultValue() {
    if (is("{")) { next(); expect("}"); return "{}"; }
    if (is("[")) { next(); expect("]"); return "{}"; }
    const token = next();
    return token.kind === "string" ? JSON.stringify(token.value) : token.value;
  }
  function args() {
    expect("(");
    const list = [];
    while (!is(")")) {
      skipExtAttrs();
      let optional = false;
      if (is("optional")) { next(); optional = true; }
      const argType = type();
      let variadic = false;
      if (is("...")) { next(); variadic = true; }
      const name = ident();
      let value;
      if (is("=")) { next(); value = defaultValue(); }
      list.push({ name, type: argType, optional, variadic, value });
      if (is(",")) next();
    }
    expect(")");
    return list;
  }
  function members(kind) {
    expect("{");
    const list = [];
    while (!is("}")) {
      skipExtAttrs();
      if (kind === "dictionary") {
        let required = false;
        if (is("required")) { next(); required = true; }
        skipExtAttrs();
        const memberType = type();
        const name = ident();
        let value;
        if (is("=")) { next(); value = defaultValue(); }
        expect(";");
        list.push({ kind: "field", name, type: memberType, required, value });
        continue;
      }
      if (is("const")) {
        next(); const constType = type(); const name = ident(); expect("="); const value = next().value; expect(";");
        list.push({ kind: "const", name, type: constType, value });
        continue;
      }
      if (is("constructor")) { next(); args(); expect(";"); continue; }
      let isStatic = false, readonly = false;
      while (["static", "readonly", "inherit", "getter", "setter", "deleter", "stringifier"].includes(peek().value) && peek(1).value !== "(") {
        const word = next().value;
        if (word === "static") isStatic = true;
        if (word === "readonly") readonly = true;
        if (word === "stringifier" && is(";")) break;
      }
      if (is(";")) { next(); continue; }
      if (["setlike", "iterable", "maplike", "async"].includes(peek().value)) {
        const like = next().value;
        if (like === "async") next();
        expect("<"); const itemTypes = [type()]; if (is(",")) { next(); itemTypes.push(type()); } expect(">"); expect(";");
        list.push({ kind: like, types: itemTypes, readonly });
        continue;
      }
      if (is("attribute")) {
        next(); const attrType = type(); const name = ident(); expect(";");
        list.push({ kind: "attribute", name, type: attrType, readonly, isStatic });
        continue;
      }
      const returns = type();
      const name = ident();
      const params = args();
      expect(";");
      list.push({ kind: "operation", name, returns, params, isStatic });
    }
    expect("}");
    expect(";");
    return list;
  }
  const definitions = [];
  while (i < t.length) {
    skipExtAttrs();
    if (i >= t.length) break;
    let partial = false;
    if (is("partial")) { next(); partial = true; }
    if (is("callback")) {
      next();
      if (is("interface")) { next(); const name = ident(); definitions.push({ kind: "callback interface", name, members: members("interface") }); continue; }
      const name = ident(); expect("="); const returns = type(); const params = args(); expect(";");
      definitions.push({ kind: "callback", name, returns, params });
      continue;
    }
    if (is("interface") || is("namespace")) {
      const kind = next().value;
      let mixin = false;
      if (is("mixin")) { next(); mixin = true; }
      const name = ident();
      let parent;
      if (is(":")) { next(); parent = ident(); }
      definitions.push({ kind: mixin ? "mixin" : kind, name, parent, partial, members: members(kind) });
      continue;
    }
    if (is("dictionary")) {
      next(); const name = ident();
      let parent;
      if (is(":")) { next(); parent = ident(); }
      definitions.push({ kind: "dictionary", name, parent, partial, members: members("dictionary") });
      continue;
    }
    if (is("enum")) {
      next(); const name = ident(); expect("{");
      const values = [];
      while (!is("}")) { values.push(next().value); if (is(",")) next(); }
      expect("}"); expect(";");
      definitions.push({ kind: "enum", name, values });
      continue;
    }
    if (is("typedef")) {
      next(); const typedefType = type(); const name = ident(); expect(";");
      definitions.push({ kind: "typedef", name, type: typedefType });
      continue;
    }
    if (peek(1) && peek(1).value === "includes") {
      const target = ident(); next(); const mixin = ident(); expect(";");
      definitions.push({ kind: "includes", target, mixin });
      continue;
    }
    throw new Error(`WebIDL: unexpected ${peek().value}`);
  }
  return definitions;
}

// ------------------------------------------------------------------- model
function model(definitions) {
  const types = new Map();
  const includes = new Map();
  for (const d of definitions) {
    if (d.kind === "includes") {
      if (!includes.has(d.target)) includes.set(d.target, []);
      includes.get(d.target).push(d.mixin);
      continue;
    }
    const prior = types.get(d.name);
    if (prior && (d.partial || prior.partialOnly)) {
      prior.members.push(...d.members);
      if (!d.partial) { Object.assign(prior, { ...d, members: prior.members }); delete prior.partialOnly; }
      continue;
    }
    types.set(d.name, { ...d, members: d.members ? [...d.members] : undefined, partialOnly: d.partial || undefined });
  }
  return { types, includes };
}

// ---------------------------------------------------------- type mapping
const LUA_KEYWORDS = new Set("and break do else elseif end false for function goto if in local nil not or repeat return then true until while".split(" "));
const NUMBERS = new Set(["byte", "octet", "short", "unsigned short", "long", "unsigned long", "long long", "unsigned long long"]);
const FLOATS = new Set(["float", "unrestricted float", "double", "unrestricted double"]);
const STRINGS = new Set(["DOMString", "USVString", "ByteString", "CSSOMString"]);

function knownExternal() {
  const names = new Set();
  for (const file of readdirSync(typesDir)) {
    if (!file.endsWith(".d.lua") || OUTPUTS.some((o) => o.file === file)) continue;
    for (const m of readFileSync(join(typesDir, file), "utf8").matchAll(/---@(?:class|alias)\s+(?:\([^)]*\)\s*)?([A-Za-z_][\w.]*)/g)) names.add(m[1]);
  }
  return names;
}

function luaType(node, ctx, position = "value") {
  let text;
  if (node.kind === "union") {
    text = [...new Set(node.items.map((item) => luaType(item, ctx, position)))].join("|");
  } else if (node.kind === "generic") {
    const [a, b] = node.args;
    if (node.name === "Promise") text = position === "return" ? luaType(a, ctx) : "HostPromise";
    else if (node.name === "record") text = `table<${luaType(a, ctx)}, ${luaType(b, ctx)}>`;
    else {
      const inner = luaType(a, ctx);
      text = /[|]/.test(inner) ? `(${inner})[]` : `${inner}[]`;
    }
  } else {
    const name = node.name;
    if (name === "undefined" || name === "void") text = "nil";
    else if (name === "boolean") text = "boolean";
    else if (NUMBERS.has(name)) text = "integer";
    else if (FLOATS.has(name)) text = "number";
    else if (name === "bigint") text = "integer";
    else if (STRINGS.has(name)) text = "string";
    else if (name === "any" || name === "object") text = "any";
    else if (ctx.types.has(name)) text = ctx.types.get(name).kind === "callback" ? luaCallback(ctx.types.get(name), ctx) : name;
    else if (ctx.external.has(name)) text = name;
    else { ctx.unknown.add(name); text = "any"; }
  }
  if (node.nullable && text !== "any" && text !== "nil") text = /[|]/.test(text) && !text.startsWith("(") ? `${text}|nil` : `${text}|nil`;
  return text;
}

function luaCallback(def, ctx) {
  const params = def.params.map((p) => `${luaName(p.name)}${p.optional ? "?" : ""}: ${luaType(p.type, ctx)}`).join(", ");
  const returns = luaType(def.returns, ctx, "return");
  return `fun(${params})${returns === "nil" ? "" : ": " + returns}`;
}

const luaName = (name) => (LUA_KEYWORDS.has(name) ? name + "_" : name);
const desc = (text) => (text ? " " + text.replace(/\s+/g, " ") : "");

function hexValue(value) {
  if (/^0[xX]/.test(value)) return value;
  return value;
}

// MDN documents mixin members under the interface that exposes them.
const MDN_HOME = {
  WebGLRenderingContextBase: "WebGLRenderingContext", WebGLRenderingContextOverloads: "WebGLRenderingContext",
  WebGL2RenderingContextBase: "WebGL2RenderingContext", WebGL2RenderingContextOverloads: "WebGL2RenderingContext",
  GPUObjectBase: "GPUBuffer", GPUPipelineBase: "GPURenderPipeline", GPUCommandsMixin: "GPUCommandEncoder",
  GPUDebugCommandsMixin: "GPUCommandEncoder", GPUBindingCommandsMixin: "GPURenderPassEncoder", GPURenderCommandsMixin: "GPURenderPassEncoder",
  NavigatorGPU: "Navigator",
};
const mdn = (owner, member) => `[MDN](https://developer.mozilla.org/docs/Web/API/${MDN_HOME[owner] || owner}${member ? "/" + member : ""})`;

// ------------------------------------------------------------------ emitter
function emit(output, ctx) {
  const out = [];
  out.push("---@meta");
  out.push(`-- ${output.title} for Lua components, generated by dom/webidl/generate.mjs from the`);
  out.push("-- specifications' WebIDL (dom/webidl/idl). Do not edit by hand.");
  out.push(`-- ${output.note}`);
  out.push("");
  const order = [...ctx.local].sort((a, b) => a.localeCompare(b));
  for (const name of order) {
    const def = ctx.types.get(name);
    if (def.kind === "typedef") {
      out.push(`---@alias ${name} ${luaType(def.type, ctx)}`);
      out.push("");
    } else if (def.kind === "enum") {
      out.push(`---@alias ${name}`);
      for (const value of def.values) out.push(`---| ${JSON.stringify(value)}`);
      out.push("");
    } else if (def.kind === "callback") {
      out.push(`---@alias ${name} ${luaCallback(def, ctx)}`);
      out.push("");
    } else if (def.kind === "dictionary") {
      const parent = def.parent && ctx.types.has(def.parent) ? ` : ${def.parent}` : "";
      out.push(`---@class ${name}${parent}`);
      for (const m of def.members) {
        const note = [m.required ? "Required." : "", m.value !== undefined ? `Default ${m.value}.` : ""].filter(Boolean).join(" ");
        out.push(`---@field ${m.name}${m.required ? "" : "?"} ${luaType(m.type, ctx)}${desc(note)}`);
      }
      out.push("");
    } else {
      emitInterface(name, def, ctx, out);
    }
  }
  return out.join("\n").replace(/\n+$/, "\n");
}

function emitInterface(name, def, ctx, out) {
  const parents = [];
  if (def.parent && (ctx.types.has(def.parent) || ctx.external.has(def.parent))) parents.push(def.parent);
  for (const mixin of ctx.includes.get(name) || []) parents.push(mixin);
  const kindNote = def.kind === "namespace" ? " (a namespace of constants)" : def.kind === "mixin" ? " (members shared by the interfaces that include it)" : "";
  out.push(`--- ${mdn(name)}${kindNote}`);
  out.push(`---@class ${name}${parents.length ? " : " + parents.join(", ") : ""}`);
  const operations = new Map();
  for (const m of def.members) {
    if (m.kind === "const") out.push(`---@field ${m.name} integer ${hexValue(m.value)}`);
    else if (m.kind === "attribute") out.push(`---@field ${m.name} ${luaType(m.type, ctx)}${desc(`${m.readonly ? "Read-only. " : ""}${mdn(name, m.name)}`)}`);
    else if (m.kind === "setlike") {
      const item = luaType(m.types[0], ctx);
      out.push(`---@field size integer`);
      out.push(`---@field has fun(self: ${name}, value: ${item}): boolean`);
    } else if (m.kind === "operation" && !m.isStatic) {
      if (!operations.has(m.name)) operations.set(m.name, []);
      operations.get(m.name).push(m);
    }
  }
  if (!operations.size) { out.push(""); return; }
  out.push(`local ${name} = {}`);
  out.push("");
  for (const [opName, overloads] of operations) {
    const [main, ...rest] = overloads;
    const promise = main.returns.kind === "generic" && main.returns.name === "Promise";
    out.push(`--- ${mdn(name, opName)}${promise ? "\n--- Suspends the calling Lua task until the promise settles." : ""}`);
    for (const p of main.params) {
      const pType = luaType(p.type, ctx);
      if (p.variadic) out.push(`---@param ... ${pType}`);
      else out.push(`---@param ${luaName(p.name)}${p.optional ? "?" : ""} ${pType}${desc(p.value !== undefined ? `Default ${p.value}.` : "")}`);
    }
    const returns = luaType(main.returns, ctx, "return");
    if (returns !== "nil") out.push(`---@return ${returns}`);
    for (const o of rest) {
      const params = [`self: ${name}`, ...o.params.map((p) => (p.variadic ? `...: ${luaType(p.type, ctx)}` : `${luaName(p.name)}${p.optional ? "?" : ""}: ${luaType(p.type, ctx)}`))].join(", ");
      const r = luaType(o.returns, ctx, "return");
      out.push(`---@overload fun(${params})${r === "nil" ? "" : ": " + r}`);
    }
    const names = main.params.map((p) => (p.variadic ? "..." : luaName(p.name))).join(", ");
    if (LUA_KEYWORDS.has(opName)) out.push(`${name}[${JSON.stringify(opName)}] = function(self${names ? ", " + names : ""}) end`);
    else out.push(`function ${name}:${opName}(${names}) end`);
    out.push("");
  }
}

// --------------------------------------------------------------------- main
const external = knownExternal();
const generated = new Map();
const unknownAll = new Set();
const shared = model(OUTPUTS.flatMap((o) => o.idl.flatMap((file) => parse(readFileSync(join(here, "idl", file), "utf8")))));
for (const output of OUTPUTS) {
  const local = new Set();
  for (const file of output.idl) for (const d of parse(readFileSync(join(here, "idl", file), "utf8"))) if (d.name && !d.partial) local.add(d.name);
  // Partial definitions extend types defined elsewhere (Navigator): emit the
  // mixins they add, not the external interface itself.
  const ctx = { types: shared.types, includes: shared.includes, external, unknown: new Set(), local };
  generated.set(output.file, emit(output, ctx));
  for (const name of ctx.unknown) unknownAll.add(name);
}

if (process.argv.includes("--check")) {
  let stale = false;
  for (const [file, text] of generated) {
    let current = "";
    try { current = readFileSync(join(typesDir, file), "utf8"); } catch {}
    if (current !== text) { console.error(`dom/types/dom/${file} is stale: run node dom/webidl/generate.mjs`); stale = true; }
  }
  process.exit(stale ? 1 : 0);
}
for (const [file, text] of generated) writeFileSync(join(typesDir, file), text);
console.log(`Wrote ${[...generated.keys()].map((f) => "dom/types/dom/" + f).join(", ")}.`);
if (unknownAll.size) console.log(`Typed as any (not in Hydronium's types): ${[...unknownAll].sort().join(", ")}`);
