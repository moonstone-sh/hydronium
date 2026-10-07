// LUAX tag structure for editors: one dependency-free scanner shared by the
// VS Code / Codium extension and the browser playground (Monaco).
//
// It mirrors hydronium_luax.lexer's modes (LUA, JSX_TAG, JSX_CHILDREN) and its
// rule for when `<` opens a tag (Lexer:can_start_jsx), but unlike the compiler
// it never throws: half-typed code still yields every element it can, with
// `close: null` for the ones not closed yet. Offsets are UTF-16 indices into
// the string, as both editors use.

const EXPR_KEYWORDS = new Set(["return", "then", "else", "do", "in", "and", "or", "not", "repeat"]);
const EXPR_PUNCTS = new Set(["=", "(", "[", "{", ",", ":", ";", "+", "-", "*", "/", "..", "==", "~="]);
const NAME_PART = /[A-Za-z_][A-Za-z0-9_-]*/y;
const ATTR_NAME = /[A-Za-z_][A-Za-z0-9_-]*/y;

/**
 * @typedef {{ start: number, end: number }} Range
 * @typedef {{
 *   name: string, fragment: boolean, selfClosing: boolean,
 *   open: Range, openName: Range | null, attributes: { name: string, range: Range }[],
 *   close: Range | null, closeName: Range | null,
 *   parent: number, depth: number
 * }} LuaxElement
 */

/**
 * Scans `text` and returns every element in document order.
 * @param {string} text
 * @returns {{ elements: LuaxElement[], contexts: { kind: string, start: number, end: number, element: number }[] }}
 */
export function scan(text) {
  const elements = [];
  // Where each byte range sits, for completion: "lua", "tag" (attribute
  // area), "attr-value" (quoted), "children" (text).
  const contexts = [];
  const stack = []; // open element indices
  const n = text.length;
  let i = 0;
  let prev = null; // last significant LUA token: { kind: "keyword"|"punct"|"other", value }

  const mark = (kind, start, end, element) => {
    if (end > start) contexts.push({ kind, start, end, element });
  };

  const readName = (at) => {
    NAME_PART.lastIndex = at;
    let m = NAME_PART.exec(text);
    if (!m) return null;
    let end = NAME_PART.lastIndex;
    while (text[end] === "." ) {
      NAME_PART.lastIndex = end + 1;
      m = NAME_PART.exec(text);
      if (!m) break;
      end = NAME_PART.lastIndex;
    }
    return { start: at, end };
  };

  // Skips a Lua string or long bracket starting at `at`; returns its end.
  const skipString = (at) => {
    const q = text[at];
    if (q === '"' || q === "'") {
      let j = at + 1;
      while (j < n && text[j] !== q && text[j] !== "\n") j += text[j] === "\\" ? 2 : 1;
      return Math.min(j + 1, n);
    }
    const long = /^\[(=*)\[/.exec(text.slice(at, at + 64));
    if (long) {
      const close = "]" + long[1] + "]";
      const j = text.indexOf(close, at + long[0].length);
      return j === -1 ? n : j + close.length;
    }
    return at;
  };

  const skipComment = (at) => {
    // at points at "--"
    const long = /^--\[(=*)\[/.exec(text.slice(at, at + 66));
    if (long) {
      const close = "]" + long[1] + "]";
      const j = text.indexOf(close, at + long[0].length);
      return j === -1 ? n : j + close.length;
    }
    const nl = text.indexOf("\n", at);
    return nl === -1 ? n : nl;
  };

  // LUA mode until an unmatched `}` (when inBraces) or end of input.
  // Returns the index of that `}` (or n).
  const lua = (from, inBraces, owner) => {
    let depth = 0;
    let j = from;
    let segment = from;
    const flush = (to) => { mark("lua", segment, to, owner); };
    while (j < n) {
      const c = text[j];
      if (c === "-" && text[j + 1] === "-") { j = skipComment(j); continue; }
      if (c === '"' || c === "'" || (c === "[" && /^\[=*\[/.test(text.slice(j, j + 64)))) {
        j = skipString(j); prev = { kind: "other" }; continue;
      }
      if (/\s/.test(c)) { j++; continue; }
      if (c === "{") { depth++; prev = { kind: "punct", value: "{" }; j++; continue; }
      if (c === "}") {
        if (depth === 0 && inBraces) { flush(j); return j; }
        depth--; prev = { kind: "other" }; j++; continue;
      }
      if (c === "<" && text[j + 1] !== "=" && text[j + 1] !== "<" && canStart()) {
        flush(j);
        j = element(j, owner);
        segment = j;
        prev = { kind: "other" };
        continue;
      }
      const word = /^[A-Za-z_][A-Za-z0-9_]*/.exec(text.slice(j, j + 64));
      if (word) { prev = EXPR_KEYWORDS.has(word[0]) ? { kind: "keyword", value: word[0] } : { kind: "other" }; j += word[0].length; continue; }
      const num = /^[0-9][0-9A-Za-z_.]*/.exec(text.slice(j, j + 64));
      if (num) { prev = { kind: "other" }; j += num[0].length; continue; }
      const punct = /^(\.\.\.|\.\.|==|~=|<=|>=|::|<<|>>|\/\/|[=()[\],:;+\-*/%^#&|~<>.])/.exec(text.slice(j, j + 3));
      if (punct) { prev = { kind: "punct", value: punct[0] }; j += punct[0].length; continue; }
      prev = { kind: "other" }; j++;
    }
    flush(n);
    return n;
  };

  const canStart = () => {
    if (!prev) return true;
    if (prev.kind === "keyword") return EXPR_KEYWORDS.has(prev.value);
    if (prev.kind === "punct") return EXPR_PUNCTS.has(prev.value);
    if (prev.kind === "expr-open") return true;
    return false;
  };

  // `{ … }` inside a tag or children: LUA until its matching `}`.
  const expression = (at, owner) => {
    // {-- … --} and {/* … */} are comments in children.
    if (text.startsWith("--", at + 1) || text.startsWith("/*", at + 1)) {
      const re = text.startsWith("--", at + 1) ? /--\s*}/g : /\*\/\s*}/g;
      re.lastIndex = at + 3;
      const m = re.exec(text);
      if (m) return m.index + m[0].length;
    }
    const spread = text.startsWith("...", at + 1);
    prev = { kind: "expr-open" };
    const end = lua(at + 1 + (spread ? 3 : 0), true, owner);
    return end < n ? end + 1 : n;
  };

  // Element starting at `<`; returns the index after it.
  const element = (at, parent) => {
    const index = elements.length;
    const fragment = text[at + 1] === ">";
    const nameRange = fragment ? null : readName(at + 1);
    const el = {
      name: fragment ? "" : nameRange ? text.slice(nameRange.start, nameRange.end) : "",
      fragment, selfClosing: false,
      open: { start: at, end: at + 1 }, openName: nameRange, attributes: [],
      close: null, closeName: null,
      parent: parent ?? -1, depth: stack.length,
    };
    elements.push(el);
    stack.push(index);
    let j = fragment ? at + 2 : nameRange ? nameRange.end : at + 1;

    if (!fragment) {
      // JSX_TAG: attributes until `>` or `/>`.
      let tagStart = j;
      while (j < n) {
        const c = text[j];
        if (c === ">" ) { mark("tag", tagStart, j, index); j++; break; }
        if (c === "/" && text[j + 1] === ">") { mark("tag", tagStart, j, index); el.selfClosing = true; j += 2; el.open.end = j; stack.pop(); return j; }
        if (c === "-" && text[j + 1] === "-") { j = skipComment(j); continue; }
        if (c === '"' || c === "'") {
          mark("tag", tagStart, j, index);
          const end = skipString(j);
          mark("attr-value", j, end, index);
          j = tagStart = end;
          continue;
        }
        if (c === "{") {
          mark("tag", tagStart, j, index);
          j = tagStart = expression(j, index);
          continue;
        }
        if (c === "<") { mark("tag", tagStart, j, index); el.open.end = j; return j; } // unfinished tag
        ATTR_NAME.lastIndex = j;
        const attr = ATTR_NAME.exec(text);
        if (attr) {
          el.attributes.push({ name: attr[0], range: { start: j, end: ATTR_NAME.lastIndex } });
          j = ATTR_NAME.lastIndex;
          continue;
        }
        j++;
      }
      el.open.end = j;
      if (j >= n && text[n - 1] !== ">") { mark("tag", tagStart, n, index); return n; }
    } else {
      el.open.end = j;
    }

    // JSX_CHILDREN until the closing tag.
    let textStart = j;
    while (j < n) {
      const c = text[j];
      if (c === "<") {
        mark("children", textStart, j, index);
        if (text[j + 1] === "/") {
          // </name> or </>
          if (text[j + 2] === ">") {
            el.close = { start: j, end: j + 3 };
            el.closeName = null;
          } else {
            const name = readName(j + 2);
            let end = name ? name.end : j + 2;
            const gt = text[end] === ">" ? end + 1 : end;
            el.close = { start: j, end: gt };
            el.closeName = name;
          }
          stack.pop();
          return el.close.end;
        }
        j = element(j, index);
        textStart = j;
        continue;
      }
      if (c === "{") {
        mark("children", textStart, j, index);
        j = textStart = expression(j, index);
        continue;
      }
      j++;
    }
    mark("children", textStart, n, index);
    stack.pop();
    return n;
  };

  lua(0, false, -1);
  return { elements, contexts };
}

const contains = (range, offset) => range && offset >= range.start && offset <= range.end;

/** The innermost element whose open or close tag name contains `offset`. */
export function elementAtName(text, offset, parsed = scan(text)) {
  let best = -1;
  parsed.elements.forEach((el, index) => {
    if (contains(el.openName, offset) || contains(el.closeName, offset)) {
      if (best === -1 || el.depth >= parsed.elements[best].depth) best = index;
    }
  });
  return best === -1 ? null : { index: best, element: parsed.elements[best] };
}

/** The innermost element whose tags span `offset`. */
export function elementAt(text, offset, parsed = scan(text)) {
  let best = -1;
  parsed.elements.forEach((el, index) => {
    const end = el.close ? el.close.end : el.open.end;
    if (offset >= el.open.start && offset <= end) {
      if (best === -1 || el.depth >= parsed.elements[best].depth) best = index;
    }
  });
  return best === -1 ? null : { index: best, element: parsed.elements[best] };
}

/**
 * Linked editing: both name ranges when `offset` is on an element's open or
 * close name and the element is closed with a named tag.
 * @returns {Range[] | null}
 */
export function linkedNameRanges(text, offset, parsed = scan(text)) {
  const hit = elementAtName(text, offset, parsed);
  if (!hit || !hit.element.openName || !hit.element.closeName) return null;
  return [hit.element.openName, hit.element.closeName];
}

/**
 * After `>` was typed at `offset - 1`: the closing tag to insert at `offset`,
 * or null. Fragments close with `</>`.
 */
export function autoCloseTag(text, offset, parsed = scan(text)) {
  if (text[offset - 1] !== ">" || text[offset - 2] === "/") return null;
  for (const el of parsed.elements) {
    if (el.open.end === offset && !el.selfClosing && (el.fragment || el.name)) {
      if (el.close && el.close.start >= offset) {
        // Already closed -- unless that close actually belongs to an outer
        // element of the same name the user is nesting inside.
        const outer = parsed.elements[el.parent];
        if (!(outer && outer.name === el.name && !outer.close)) return null;
      }
      return el.fragment ? "</>" : `</${el.name}>`;
    }
  }
  return null;
}

/** Text edits that delete the element at `offset` with its children. */
export function removeTagEdits(text, offset, parsed = scan(text)) {
  const hit = elementAt(text, offset, parsed);
  if (!hit) return null;
  const el = hit.element;
  return [{ start: el.open.start, end: el.close ? el.close.end : el.open.end, text: "" }];
}

/** Text edits that drop the element's tags and keep its children. */
export function unwrapTagEdits(text, offset, parsed = scan(text)) {
  const hit = elementAt(text, offset, parsed);
  if (!hit || hit.element.selfClosing || !hit.element.close) return null;
  const el = hit.element;
  return [
    { start: el.close.start, end: el.close.end, text: "" },
    { start: el.open.start, end: el.open.end, text: "" },
  ];
}

/** Text edits that rename the element at `offset` (open and close tags). */
export function renameTagEdits(text, offset, newName, parsed = scan(text)) {
  const hit = elementAtName(text, offset, parsed) || elementAt(text, offset, parsed);
  if (!hit || hit.element.fragment || !hit.element.openName) return null;
  const el = hit.element;
  const edits = [];
  if (el.closeName) edits.push({ start: el.closeName.start, end: el.closeName.end, text: newName });
  edits.push({ start: el.openName.start, end: el.openName.end, text: newName });
  return edits;
}

/**
 * What the cursor is completing:
 *   { kind: "tag", prefix, range }           after `<` / `<d.` / `<Comp`
 *   { kind: "close", name, range }           after `</`
 *   { kind: "attribute", tag, prefix, range, present }  inside an open tag
 *   null                                     anything else
 */
export function completionContext(text, offset, parsed = scan(text)) {
  // `</` or `</na` -> the innermost unclosed element's name.
  const closeMatch = /<\/([A-Za-z0-9_.-]*)$/.exec(text.slice(Math.max(0, offset - 128), offset));
  if (closeMatch) {
    const start = offset - closeMatch[1].length;
    const before = scan(text.slice(0, offset - closeMatch[0].length));
    const open = [...before.elements].reverse().find((el) => !el.close && !el.selfClosing && el.open.end <= offset - closeMatch[0].length && (el.name || el.fragment));
    return open ? { kind: "close", name: open.fragment ? "" : open.name, range: { start, end: offset } } : null;
  }
  for (const el of parsed.elements) {
    if (el.openName && offset >= el.openName.start && offset <= el.openName.end) {
      return { kind: "tag", prefix: text.slice(el.openName.start, offset), range: { start: el.openName.start, end: el.openName.end } };
    }
  }
  // A bare `<` just typed in an expression position parses as an element with no name.
  const bare = parsed.elements.find((el) => !el.openName && !el.fragment && el.open.start === offset - 1);
  if (bare) return { kind: "tag", prefix: "", range: { start: offset, end: offset } };
  const ctx = [...parsed.contexts].reverse().find((c) => offset >= c.start && offset <= c.end && c.kind === "tag");
  if (ctx) {
    const el = parsed.elements[ctx.element];
    const word = /[A-Za-z0-9_-]*$/.exec(text.slice(ctx.start, offset))[0];
    return {
      kind: "attribute", tag: el.name, prefix: word,
      range: { start: offset - word.length, end: offset },
      present: el.attributes.map((a) => a.name),
    };
  }
  return null;
}

/**
 * Attributes a tag accepts, resolved through the props class's parents in
 * dom-data.json. `tag` is the name without its namespace (`button`, or
 * `lua.island` / `js.island` for `d.lua.island`).
 */
export function tagAttributes(domData, tag) {
  const info = domData.tags[tag];
  if (!info) return null;
  const out = {};
  const seen = new Set();
  const visit = (name) => {
    const cls = domData.classes[name];
    if (!cls || seen.has(name)) return;
    seen.add(name);
    cls.parents.forEach(visit);
    Object.assign(out, cls.fields);
  };
  visit(info.props);
  return out;
}

/** Splits `d.button` / `d.lua.island` into its namespace and tag key. */
export function intrinsicName(name) {
  const m = /^([A-Za-z_][A-Za-z0-9_]*)\.(.+)$/.exec(name);
  return m ? { namespace: m[1], tag: m[2] } : null;
}
