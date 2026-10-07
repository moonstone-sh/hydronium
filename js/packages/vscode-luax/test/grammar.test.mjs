// The LUAX TextMate grammar (luax/syntaxes/luax.tmLanguage.json), checked
// against luax/editor/luax-tags.mjs (which mirrors the compiler's lexer) on
// every .luax file in the repo: opening and closing names are tag names,
// children are text (never Lua keywords), and `<` as less-than stays Lua.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vsctm from "vscode-textmate";
import oniguruma from "vscode-oniguruma";
import { scan } from "../../../../luax/editor/luax-tags.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../../../..");
const require = createRequire(import.meta.url);
await oniguruma.loadWASM(readFileSync(require.resolve("vscode-oniguruma/release/onig.wasm")).buffer);
const registry = new vsctm.Registry({
  onigLib: Promise.resolve({ createOnigScanner: (p) => new oniguruma.OnigScanner(p), createOnigString: (s) => new oniguruma.OnigString(s) }),
  loadGrammar: async (scope) => (scope === "source.luax" ? vsctm.parseRawGrammar(readFileSync(join(repo, "luax/syntaxes/luax.tmLanguage.json"), "utf8"), "luax.json") : null),
});
const grammar = await registry.loadGrammar("source.luax");

function scopes(text) {
  const at = new Array(text.length);
  let state = vsctm.INITIAL, offset = 0;
  for (const line of text.split("\n")) {
    const r = grammar.tokenizeLine(line, state);
    state = r.ruleStack;
    for (const t of r.tokens) for (let i = t.startIndex; i < Math.min(t.endIndex, line.length); i++) at[offset + i] = t.scopes;
    offset += line.length + 1;
  }
  return at;
}
const has = (list, prefix) => (list || []).some((s) => s.startsWith(prefix));

test("less-than is Lua; tags start only where an expression can", () => {
  const src = "local a = x < y and 1\nlocal b = x<y\nif n <limit then return <d.p>ok</d.p> end\nlocal c = 1\n";
  const at = scopes(src);
  assert.ok(has(at[src.indexOf("< y")], "keyword.operator"));
  assert.ok(has(at[src.indexOf("<limit")], "keyword.operator"));
  assert.ok(has(at[src.indexOf("d.p>ok") + 2], "entity.name.tag"));
  assert.ok(has(at[src.lastIndexOf("local")], "storage") || has(at[src.lastIndexOf("local")], "keyword"), "Lua after the tag is still Lua");
});

test("every .luax file: names are tags, children are text", () => {
  const files = [];
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      if (["node_modules", ".git", ".moonstone", "dist", "zig-out", ".cache"].includes(name)) continue;
      const p = join(dir, name);
      if (statSync(p).isDirectory()) walk(p);
      else if (name.endsWith(".luax") && !/error|invalid|broken|malformed|fail/i.test(p)) files.push(p);
    }
  };
  walk(repo);
  assert.ok(files.length >= 20);
  const problems = [];
  let count = 0;
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    const at = scopes(text);
    const { elements, contexts } = scan(text);
    for (const el of elements) {
      count++;
      for (const name of [el.openName, el.closeName].filter(Boolean)) {
        if (!has(at[name.end - 1], "entity.name.tag")) problems.push(`${file.replace(repo + "/", "")}: <${el.name}> name at ${name.start}`);
      }
    }
    for (const c of contexts.filter((c) => c.kind === "children")) {
      for (let i = c.start; i < c.end; i++) {
        if (has(at[i], "keyword") || has(at[i], "storage") || has(at[i], "constant.numeric")) { problems.push(`${file.replace(repo + "/", "")}: child text as Lua at ${i}`); break; }
      }
    }
  }
  assert.ok(count > 200);
  assert.deepEqual(problems.slice(0, 10), []);
});
