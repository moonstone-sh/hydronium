#!/usr/bin/env node
// Editor data for `<d.…>` tags, extracted from the same LuaCATS files LuaLS
// reads (dom/types/dom/*.d.lua, luax/types/luax.d.lua), so completion and
// hover in editors without LuaLS (Monaco) say exactly what the types say.
//
//   node luax/editor/build-dom-data.mjs          writes luax/editor/dom-data.json
//   node luax/editor/build-dom-data.mjs --check  exits 1 when the file is stale
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../..");
const OUT = join(here, "dom-data.json");

const sources = [
  ...readdirSync(join(repo, "dom/types/dom")).filter((f) => f.endsWith(".d.lua")).sort().map((f) => join(repo, "dom/types/dom", f)),
  join(repo, "luax/types/luax.d.lua"),
];

/** Parses `---@class` / `---@field` blocks with their preceding `---` docs. */
export function parseClasses(text) {
  const classes = {};
  let current = null;
  let doc = [];
  for (const raw of text.split("\n")) {
    const line = raw.trimEnd();
    const cls = line.match(/^---@class\s+([\w.]+)(?:<[^>]*>)?\s*(?::\s*(.+))?$/);
    if (cls) {
      const parents = (cls[2] || "").split(",").map((p) => p.trim()).filter((p) => /^[\w.]+$/.test(p));
      current = classes[cls[1]] ||= { doc: "", parents: [], fields: {} };
      current.parents = [...new Set([...current.parents, ...parents])];
      if (doc.length) current.doc = doc.join("\n");
      doc = [];
      continue;
    }
    const field = line.match(/^---@field\s+(\[?"?[\w$-]+"?\]?)(\?)?\s+(.+)$/);
    if (field && current) {
      const name = field[1].replace(/^\["?|"?\]$/g, "");
      if (/^\[?integer\]?$/.test(field[1]) || name === "string") continue;
      const { type, rest } = splitType(field[3]);
      current.fields[name] = { type, optional: Boolean(field[2]) || /\?$/.test(type), doc: [doc.join("\n"), rest].filter(Boolean).join("\n") };
      doc = [];
      continue;
    }
    const comment = line.match(/^---(?!@)\s?(.*)$/);
    if (comment) { doc.push(comment[1]); continue; }
    if (!line.startsWith("---@")) { current = line === "" ? current : null; doc = []; }
  }
  return classes;
}

// A field's type runs until the first space outside <>, (), {} and quotes;
// whatever follows is its inline doc.
function splitType(text) {
  let depth = 0;
  let quote = null;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote) { if (c === quote) quote = null; continue; }
    if (c === '"' || c === "'") quote = c;
    else if ("<({[".includes(c)) depth++;
    else if (">)}]".includes(c)) depth--;
    else if (c === " " && depth === 0) {
      // `a | b` and `fun(x): y` keep going across spaces.
      const after = text.slice(i + 1);
      const before = text.slice(0, i);
      if (/^(\||:|\.\.\.)/.test(after) || /(\||:|,)$/.test(before)) continue;
      return { type: before, rest: after.trim() };
    }
  }
  return { type: text, rest: "" };
}

export function buildDomData(texts) {
  const classes = {};
  for (const text of texts) {
    for (const [name, cls] of Object.entries(parseClasses(text))) {
      const into = classes[name] ||= { doc: "", parents: [], fields: {} };
      into.doc ||= cls.doc;
      into.parents = [...new Set([...into.parents, ...cls.parents])];
      Object.assign(into.fields, cls.fields);
    }
  }
  const tags = {};
  const describe = (container, prefix) => {
    for (const [name, field] of Object.entries(classes[container]?.fields || {})) {
      const intrinsic = field.type.match(/hydronium\.Intrinsic<\s*([\w.]+)\s*,\s*([\w.]+)\s*>/);
      if (intrinsic) tags[prefix + name] = { props: intrinsic[1], element: intrinsic[2], doc: field.doc };
    }
  };
  describe("HydroniumDOMDescriptors", "");
  describe("HydroniumDOMLuaNamespace", "lua.");
  describe("HydroniumDOMJsNamespace", "js.");
  // Only the classes tags can reach, so the file stays small.
  const reachable = {};
  const visit = (name) => {
    if (!classes[name] || reachable[name]) return;
    reachable[name] = classes[name];
    classes[name].parents.forEach(visit);
  };
  Object.values(tags).forEach((tag) => visit(tag.props));
  const sorted = (obj) => Object.fromEntries(Object.keys(obj).sort().map((k) => [k, obj[k]]));
  return { schema: 1, source: "dom/types/dom/*.d.lua, luax/types/luax.d.lua", tags: sorted(tags), classes: sorted(reachable) };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const json = JSON.stringify(buildDomData(sources.map((p) => readFileSync(p, "utf8")))) + "\n";
  if (process.argv.includes("--check")) {
    const current = (() => { try { return readFileSync(OUT, "utf8"); } catch { return ""; } })();
    if (current !== json) { console.error("luax/editor/dom-data.json is stale: run node luax/editor/build-dom-data.mjs"); process.exit(1); }
  } else {
    writeFileSync(OUT, json);
    const data = JSON.parse(json);
    console.log(`dom-data.json: ${Object.keys(data.tags).length} tags, ${Object.keys(data.classes).length} classes`);
  }
}
