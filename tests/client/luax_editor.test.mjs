// luax/editor: the tag scanner shared by the VS Code extension and the
// browser playground, and the DOM data both complete from.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  scan, linkedNameRanges, autoCloseTag, removeTagEdits, unwrapTagEdits,
  renameTagEdits, completionContext, tagAttributes, intrinsicName,
} from "../../luax/editor/luax-tags.mjs";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const apply = (text, edits) => [...edits].sort((a, b) => b.start - a.start)
  .reduce((out, e) => out.slice(0, e.start) + e.text + out.slice(e.end), text);
const names = (text) => scan(text).elements.map((el) => (el.fragment ? "<>" : el.name));

test("`<` opens a tag only where the LUAX lexer would", () => {
  assert.deepEqual(names("local a = b < c"), []);
  assert.deepEqual(names("if a<b then end"), []);
  assert.deepEqual(names("x = a <= b or a << 2"), []);
  assert.deepEqual(names("return <d.div/>"), ["d.div"]);
  assert.deepEqual(names("local v = <span>hi</span>"), ["span"]);
  assert.deepEqual(names("f(<A/>, <B/>)"), ["A", "B"]);
  assert.deepEqual(names("local s = '<d.div>' -- <d.p>\n--[[ <x> ]]"), []);
});

test("children, expressions, nested JSX, fragments and comments", () => {
  const src = `return <d.ul class="list">
  {-- a comment with <tags> and } --}
  {items:map(function(item) return <d.li key={item.id}>{item.label}</d.li> end)}
  <>
    <Card.Header title={"a } b"} {...rest} />
  </>
</d.ul>`;
  const { elements } = scan(src);
  assert.deepEqual(elements.map((e) => e.fragment ? "<>" : e.name), ["d.ul", "d.li", "<>", "Card.Header"]);
  assert.ok(elements.every((e) => e.close || e.selfClosing));
  assert.equal(elements[1].parent, 0);
  assert.deepEqual(elements[0].attributes.map((a) => a.name), ["class"]);
  assert.deepEqual(elements[3].attributes.map((a) => a.name), ["title"]);
});

test("half-typed code keeps every element it can", () => {
  const { elements } = scan("return <d.div class=\"a\">\n  <d.span>");
  assert.deepEqual(elements.map((e) => [e.name, e.close]), [["d.div", null], ["d.span", null]]);
});

test("linked editing ranges cover the open and close names", () => {
  const src = "return <d.div><d.p>x</d.p></d.div>";
  const ranges = linkedNameRanges(src, src.indexOf("d.p") + 1);
  assert.deepEqual(ranges.map((r) => src.slice(r.start, r.end)), ["d.p", "d.p"]);
  assert.notEqual(ranges[0].start, ranges[1].start);
  assert.equal(linkedNameRanges(src, src.indexOf("x")), null);
});

test("auto-close after `>`", () => {
  let src = "return <d.div>";
  assert.equal(autoCloseTag(src, src.length), "</d.div>");
  src = "return <>";
  assert.equal(autoCloseTag(src, src.length), "</>");
  src = "return <d.br/>";
  assert.equal(autoCloseTag(src, src.length), null);
  src = "return <d.div></d.div>";
  assert.equal(autoCloseTag(src, "return <d.div>".length), null);
  src = "local a = b > c";
  assert.equal(autoCloseTag(src, src.indexOf(">") + 1), null);
  // Typing a nested element of the same name inside a closed one.
  src = "return <d.div><d.div></d.div>";
  assert.equal(autoCloseTag(src, "return <d.div><d.div>".length), "</d.div>");
});

test("remove, unwrap and rename", () => {
  const src = "return <d.div><d.p class=\"x\">a<d.b>b</d.b></d.p></d.div>";
  const at = src.indexOf("class");
  assert.equal(apply(src, removeTagEdits(src, at)), "return <d.div></d.div>");
  assert.equal(apply(src, unwrapTagEdits(src, at)), "return <d.div>a<d.b>b</d.b></d.div>");
  assert.equal(apply(src, renameTagEdits(src, src.indexOf("d.p"), "d.section")),
    "return <d.div><d.section class=\"x\">a<d.b>b</d.b></d.section></d.div>");
  assert.equal(unwrapTagEdits("return <d.br/>", 9), null);
});

test("completion contexts", () => {
  let src = "return <d.bu";
  assert.deepEqual(completionContext(src, src.length).kind, "tag");
  assert.equal(completionContext(src, src.length).prefix, "d.bu");
  src = "return <";
  assert.equal(completionContext(src, src.length).kind, "tag");
  src = "return <d.button cl";
  const attr = completionContext(src, src.length);
  assert.equal(attr.kind, "attribute");
  assert.equal(attr.tag, "d.button");
  assert.equal(attr.prefix, "cl");
  src = "return <d.button class=\"x\" ";
  assert.deepEqual(completionContext(src, src.length).present, ["class"]);
  src = "return <d.div><d.p>x</";
  const close = completionContext(src, src.length);
  assert.equal(close.kind, "close");
  assert.equal(close.name, "d.p");
  src = "return <d.div>some text";
  assert.equal(completionContext(src, src.length), null);
  src = "return <d.div title=\"a b\">";
  assert.equal(completionContext(src, src.indexOf("a b") + 1), null);
});

test("dom-data.json is current and resolves attributes through parents", () => {
  execFileSync(process.execPath, [join(repo, "luax/editor/build-dom-data.mjs"), "--check"]);
  const data = JSON.parse(readFileSync(join(repo, "luax/editor/dom-data.json"), "utf8"));
  const button = tagAttributes(data, "button");
  assert.ok(button.disabled && button.class && button.onClick && button.key);
  assert.match(tagAttributes(data, "form").onSubmit.type, /values_literal/);
  assert.ok(tagAttributes(data, "lua.island").hydrate);
  assert.deepEqual(intrinsicName("d.lua.island"), { namespace: "d", tag: "lua.island" });
});

test("every .luax file in the repo scans with each element closed by its own name", () => {
  const files = [];
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      if (["node_modules", ".git", ".moonstone", "zig-out", "zig-cache"].includes(name)) continue;
      const path = join(dir, name);
      const st = statSync(path);
      if (st.isDirectory()) walk(path);
      else if (name.endsWith(".luax")) files.push(path);
    }
  };
  for (const dir of ["examples", "lab", "router", "dom", "create", "ink", "luax/tests", "tests"]) {
    try { walk(join(repo, dir)); } catch {}
  }
  assert.ok(files.length > 20, `expected a corpus, found ${files.length}`);
  const problems = [];
  let count = 0;
  for (const file of files) {
    const text = readFileSync(file, "utf8");
    // Files that are deliberately invalid LUAX (error fixtures) are skipped.
    if (/error|invalid|broken|malformed|fail/i.test(file)) continue;
    for (const el of scan(text).elements) {
      count++;
      if (el.selfClosing || el.fragment && el.close) continue;
      const closeName = el.closeName ? text.slice(el.closeName.start, el.closeName.end) : null;
      if (!el.close || closeName !== el.name) problems.push(`${file.replace(repo + "/", "")}: <${el.name}> at ${el.open.start} closed by ${closeName}`);
    }
  }
  assert.ok(count > 200, `expected many elements, found ${count}`);
  assert.deepEqual(problems.slice(0, 10), []);
});
