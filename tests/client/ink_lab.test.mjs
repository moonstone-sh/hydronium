import test from "node:test";
import assert from "node:assert/strict";

import {
  colorToCss, keyboardEvent, paintFrame, createFrameModel, applyFrame, flushFrameModel, createAnimationPacer, createInkLab, STANDARD_TERMINAL_SIZES, terminalSizeGroups, parseCellDimension,
} from "../../ink-lab/src/hydronium_ink_lab/client/virtual_terminal.js";

test("Ink Lab preserves terminal palette references and absolute colors", () => {
  assert.match(colorToCss({ kind: "palette", index: 9 }), /--hy-terminal-bright-red/);
  assert.equal(colorToCss({ kind: "index", index: 196 }), "rgb(255 0 0)");
  assert.equal(colorToCss({ kind: "rgb", r: 12, g: 34, b: 56 }), "rgb(12 34 56)");
});

test("Ink Lab maps browser keyboard events to Ink key events", () => {
  assert.deepEqual(keyboardEvent({
    key: "ArrowDown", ctrlKey: false, shiftKey: true, metaKey: false,
  }), {
    op: "input",
    input: "",
    key: {
      ctrl: false, shift: true, meta: false, tab: false, return: false,
      escape: false, backspace: false, delete: false, upArrow: false,
      downArrow: true, leftArrow: false, rightArrow: false, pageUp: false,
      pageDown: false, home: false, end: false,
    },
  });
});

// A minimal DOM double faithful enough for `paintFrame`/`flushFrameModel`:
// tracks children, style, and dataset the same way real elements do.
class Node {
  constructor(document, fragment = false) {
    this.ownerDocument = document;
    this.fragment = fragment;
    this.children = [];
    this.style = {};
    this.dataset = {};
    this.textContent = "";
  }
  replaceChildren(...children) {
    // Real DOM insertion moves a DocumentFragment's children into the
    // target; keep this tiny test double faithful to that behavior.
    this.children = children.flatMap((child) => child.fragment ? child.children : [child]);
  }
  appendChild(child) {
    if (child.fragment) this.children.push(...child.children);
    else this.children.push(child);
  }
}

function makeContainer() {
  const document = {
    createElement() { return new Node(document); },
    createDocumentFragment() { return new Node(document, true); },
  };
  return new Node(document);
}

const RED_BOLD = { fg: { kind: "rgb", r: 12, g: 34, b: 56 }, bg: null, bold: true, dim: false, italic: false, underline: false, strikethrough: false, inverse: false };
const GREEN = { fg: { kind: "rgb", r: 0, g: 200, b: 0 }, bg: null, bold: false, dim: false, italic: false, underline: false, strikethrough: false, inverse: false };

test("Ink Lab paints canonical cells directly from style-interned row runs", () => {
  const terminal = makeContainer();
  paintFrame(terminal, {
    version: 2, kind: "full", seq: 1, width: 1, height: 1,
    cursor: { x: 0, y: 0 }, status: { exited: false, exitReason: null, closed: false },
    styles: { 1: RED_BOLD },
    rows: [[[1, ["λ"]]]],
  });
  assert.equal(terminal.children[0].textContent, "λ");
  assert.equal(terminal.children[0].style.color, "rgb(12 34 56)");
  assert.equal(terminal.children[0].style.fontWeight, "700");
  assert.equal(terminal.children[0].dataset.cursor, "");
  assert.equal(terminal.dataset.columns, "1");
});

test("Ink Lab full frame reproduces every cell, including a wide-glyph's empty continuation cell", () => {
  const model = createFrameModel();
  const terminal = makeContainer();
  // "文" (2 cells wide) + "!" (1 cell), run-length encoded as one style run
  // whose second character is the empty continuation cell.
  applyFrame(model, {
    version: 2, kind: "full", seq: 1, width: 3, height: 1, cursor: null, status: null,
    styles: { 1: GREEN },
    rows: [[[1, ["文", "", "!"]]]],
  });
  flushFrameModel(terminal, model);
  assert.equal(terminal.children[0].textContent, "文");
  assert.equal(terminal.children[1].textContent, "");
  assert.equal(terminal.children[2].textContent, "!");
  assert.equal(terminal.children[0].style.color, "rgb(0 200 0)");
});

test("Ink Lab delta application changes only the addressed cells and reproduces a full-frame repaint", () => {
  const model = createFrameModel();
  const terminal = makeContainer();
  applyFrame(model, {
    version: 2, kind: "full", seq: 1, width: 4, height: 1, cursor: { x: 0, y: 0 }, status: null,
    styles: { 1: GREEN },
    rows: [[[1, ["a", "b", "c", "d"]]]],
  });
  flushFrameModel(terminal, model);
  assert.deepEqual(terminal.children.map((cell) => cell.textContent), ["a", "b", "c", "d"]);

  // A delta touching only column 2 must reuse the already-known style (no
  // `styles` payload) and leave every other cell's span untouched.
  const untouchedSpan = terminal.children[3];
  const { activity } = applyFrame(model, {
    version: 2, kind: "delta", seq: 2, base: 1, cursor: { x: 1, y: 0 }, status: null,
    changes: [[0, 1, 1, ["X"]]],
  });
  assert.equal(activity, true);
  flushFrameModel(terminal, model);
  assert.deepEqual(terminal.children.map((cell) => cell.textContent), ["a", "X", "c", "d"]);
  assert.equal(terminal.children[3], untouchedSpan, "an untouched cell keeps the exact same DOM node");
  assert.equal(terminal.children[0].dataset.cursor, undefined, "cursor dataset is cleared off the cell it left, even though that cell wasn't in `changes`");
  assert.equal(terminal.children[1].dataset.cursor, "");

  // Reconstructing straight from a full frame with the same content must
  // match the delta-built model cell for cell.
  const reference = createFrameModel();
  const referenceTerminal = makeContainer();
  applyFrame(reference, {
    version: 2, kind: "full", seq: 99, width: 4, height: 1, cursor: { x: 1, y: 0 }, status: null,
    styles: { 7: GREEN },
    rows: [[[7, ["a", "X", "c", "d"]]]],
  });
  flushFrameModel(referenceTerminal, reference);
  assert.deepEqual(
    terminal.children.map((cell) => [cell.textContent, cell.style.color]),
    referenceTerminal.children.map((cell) => [cell.textContent, cell.style.color]),
  );
});

test("Ink Lab delta application carries a style change and only ships genuinely new styles", () => {
  const model = createFrameModel();
  applyFrame(model, {
    version: 2, kind: "full", seq: 1, width: 2, height: 1, cursor: null, status: null,
    styles: { 1: GREEN },
    rows: [[[1, ["a", "b"]]]],
  });
  const BLUE = { fg: { kind: "rgb", r: 0, g: 0, b: 255 }, bg: null, bold: false, dim: false, italic: false, underline: false, strikethrough: false, inverse: false };
  applyFrame(model, {
    version: 2, kind: "delta", seq: 2, base: 1, cursor: null, status: null,
    styles: { 2: BLUE },
    changes: [[0, 0, 2, ["a"]]],
  });
  assert.deepEqual(model.styles.get(2), BLUE);
  assert.deepEqual(model.styles.get(1), GREEN, "a style not resent must still be resolvable from an earlier frame");
  assert.equal(model.styleIds[0], 2);
  assert.equal(model.styleIds[1], 1);
});

test("Ink Lab treats an idle delta (no changes, no cursor/status change) as no activity", () => {
  const model = createFrameModel();
  applyFrame(model, {
    version: 2, kind: "full", seq: 1, width: 2, height: 1, cursor: { x: 0, y: 0 }, status: { exited: false, exitReason: null, closed: false },
    styles: { 1: GREEN },
    rows: [[[1, ["a", "b"]]]],
  });
  const { activity } = applyFrame(model, {
    version: 2, kind: "delta", seq: 2, base: 1, cursor: { x: 0, y: 0 }, status: { exited: false, exitReason: null, closed: false },
  });
  assert.equal(activity, false);
});

test("Ink Lab rejects a delta whose base does not match the model's last applied frame", () => {
  const model = createFrameModel();
  applyFrame(model, {
    version: 2, kind: "full", seq: 1, width: 1, height: 1, cursor: null, status: null,
    styles: { 1: GREEN }, rows: [[[1, ["a"]]]],
  });
  assert.throws(() => applyFrame(model, {
    version: 2, kind: "delta", seq: 3, base: 2, cursor: null, status: null, changes: [[0, 0, 1, ["b"]]],
  }), (error) => error.desync === true);
});

test("Ink Lab's animation pacer holds a steady cadence while animating and backs off once idle", () => {
  const pacer = createAnimationPacer({ baseDelayMs: 55, idleThreshold: 3, maxDelayMs: 500, idleGrowth: 2 });
  assert.equal(pacer.delay, 55);
  pacer.noteActivity();
  pacer.noteActivity();
  assert.equal(pacer.delay, 55, "activity keeps the base cadence");

  pacer.noteIdle();
  pacer.noteIdle();
  assert.equal(pacer.delay, 55, "backoff only starts after idleThreshold consecutive idle ticks");
  pacer.noteIdle();
  assert.equal(pacer.delay, 110);
  pacer.noteIdle();
  assert.equal(pacer.delay, 220);
  pacer.noteIdle();
  assert.equal(pacer.delay, 440);
  pacer.noteIdle();
  assert.equal(pacer.delay, 500, "backoff is capped at maxDelayMs");

  pacer.noteActivity();
  assert.equal(pacer.delay, 55, "any activity resumes the base cadence immediately");
});


test("dimension presets distinguish story, saved user and standard sizes", () => {
  const groups = terminalSizeGroups({ sizes: [{ name: "default", columns: 84, rows: 4 }] }, [{ name: "90×32", columns: 90, rows: 32 }]);
  assert.deepEqual(groups.map(group => group.label), ["Story-specific", "Standard", "User-defined"]);
  assert.equal(groups[0].sizes[0].rows, 4);
  assert.equal(groups[2].sizes[0].columns, 90);
  assert.ok(groups[1].sizes.some(size => size.columns === 80 && size.rows === 24));
  assert.deepEqual(terminalSizeGroups({})[0].sizes[0], { name: "default", columns: 80, rows: 24 });
  assert.equal(terminalSizeGroups({}).length, 2, "empty user sizes should not create an empty dropdown group");
  assert.ok(Object.isFrozen(STANDARD_TERMINAL_SIZES));
});

test("editable cell counts accept padded positive cells and reject malformed input", () => {
  assert.equal(parseCellDimension("080"), 80);
  assert.equal(parseCellDimension("004"), 4);
  assert.equal(parseCellDimension("999"), 999);
  for (const value of ["", "000", "-1", "1.5", "1e2", "abc", "1000"]) assert.equal(parseCellDimension(value), null);
});

class InteractiveNode extends Node {
  constructor(document, tag = 'div', fragment = false) {
    super(document, fragment); this.tag = tag; this.attributes = new Map(); this.listeners = new Map();
    this.style.setProperty = (key, value) => { this.style[key] = value; };
  }
  setAttribute(key, value) { this.attributes.set(key, value); }
  hasAttribute(key) { return this.attributes.has(key); }
  matches(selector) { return selector.split(',').some(part => part.trim() === this.tag || (part.trim().startsWith('[') && this.attributes.has(part.trim().slice(1, -1)))); }
  querySelector(selector) {
    for (const child of this.children) { if (child.matches?.(selector)) return child; const found = child.querySelector?.(selector); if (found) return found; }
    return null;
  }
  querySelectorAll() { return []; }
  contains(node) { return node === this || this.children.some(child => child.contains?.(node)); }
  append(...children) { for (const child of children) { child.parent = this; this.appendChild(child); } }
  prepend(child) { child.parent = this; this.children.unshift(child); }
  addEventListener(type, handler) { this.listeners.set(type, [...(this.listeners.get(type) || []), handler]); }
  removeEventListener(type, handler) { this.listeners.set(type, (this.listeners.get(type) || []).filter(item => item !== handler)); }
  async fire(type, data = {}) { for (const handler of this.listeners.get(type) || []) await handler({ target: this, preventDefault() {}, ...data }); }
  focus() { this.ownerDocument.activeElement = this; }
  select() {}
  blur() { this.ownerDocument.activeElement = null; this.parent?.fire('focusout', { target: this }); }
  remove() { if(this.parent)this.parent.children=this.parent.children.filter(node=>node!==this); }
  setPointerCapture() {}
  getBoundingClientRect() { return { width: 640, height: 400, right: 640, bottom: 400 }; }
}

test('live dimension controls preserve drafts, commit Enter and blur, and save user presets', async () => {
  const harness = await inkHarness();
  try {
    const { roles, lab, document, requests, saved } = harness;
    const dimensions = roles.get('dimensions');
    const columns = dimensions.querySelector('[data-lab-columns]');
    const rows = dimensions.querySelector('[data-lab-rows]');
    columns.focus(); columns.value = '091';
    await lab.step(1000);
    assert.equal(document.activeElement, columns);
    assert.equal(columns.value, '091', 'animation must not overwrite an unfinished edit');
    await dimensions.fire('keydown', { target: columns, key: 'Enter' });
    assert.equal(roles.get('terminal').dataset.columns, '91');
    rows.focus(); rows.value = '032';
    document.activeElement = null;
    await dimensions.fire('focusout', { target: rows });
    assert.equal(roles.get('terminal').dataset.rows, '32');
    assert.deepEqual(saved.terminalSizes[0], { name: '91×32', columns: 91, rows: 32 });
    assert.deepEqual(roles.get('size').children.filter(node => node.tag === 'optgroup').map(node => node.label), ['Story-specific', 'Standard', 'User-defined']);
    const resizeCount = requests.filter(message => message.op === 'resize').length;
    rows.value = '000';
    await dimensions.fire('keydown', { target: rows, key: 'Enter' });
    assert.equal(rows.value, '032');
    assert.equal(requests.filter(message => message.op === 'resize').length, resizeCount);
  } finally { await harness.close(); }
});

test('canvas navigation pans touch descendants, handles cancellation, and preserves mouse selection', async () => {
  const harness = await inkHarness();
  try {
    const { roles } = harness;
    const stage = roles.get('stage'), viewport = roles.get('viewport');
    const leaf = roles.get('terminal').children[0];
    const initial = viewport.style.transform;
    await stage.fire('pointerdown', { target: leaf, pointerType: 'mouse', pointerId: 1, button: 0, clientX: 100, clientY: 100 });
    await stage.fire('pointermove', { pointerId: 1, clientX: 140, clientY: 150 });
    assert.equal(viewport.style.transform, initial, 'ordinary terminal mouse drags remain text selection');
    await stage.fire('pointerdown', { target: leaf, pointerType: 'touch', pointerId: 2, button: 0, clientX: 100, clientY: 100 });
    await stage.fire('pointermove', { pointerId: 2, clientX: 140, clientY: 150 });
    assert.equal(viewport.style.transform, 'translate(40px, 50px) scale(1)');
    await stage.fire('pointercancel');
    assert.equal(stage.dataset.panning, undefined);
    await stage.fire('pointermove', { pointerId: 2, clientX: 250, clientY: 250 });
    assert.equal(viewport.style.transform, 'translate(40px, 50px) scale(1)');
    await roles.get('pan-toggle').fire('click');
    await stage.fire('pointerdown', { target: leaf, pointerType: 'mouse', pointerId: 3, button: 0, clientX: 100, clientY: 100 });
    await stage.fire('pointermove', { pointerId: 3, clientX: 110, clientY: 120 });
    await stage.fire('pointerup');
    assert.equal(viewport.style.transform, 'translate(50px, 70px) scale(1)');
    await stage.fire('wheel', { deltaX: 10, deltaY: 20, deltaMode: 0 });
    assert.equal(viewport.style.transform, 'translate(40px, 50px) scale(1)');
    await stage.fire('wheel', { ctrlKey: true, deltaY: -10 });
    assert.ok(harness.saved.zoom > 1.1);
    assert.equal(viewport.style.transform, `translate(40px, 50px) scale(${harness.saved.zoom})`);
    assert.equal(roles.get('terminal').dataset.columns,'84','zoom preserves logical columns');
    assert.equal(roles.get('terminal').dataset.rows,'4','zoom preserves logical rows');
    assert.equal(harness.requests.filter(message=>message.op==='resize').length,0,'zoom does not resize the terminal');
  } finally { await harness.close(); }
});

async function inkHarness(options = {}) {
  const previous = { window: globalThis.window, document: globalThis.document, style: globalThis.getComputedStyle };
  const document = { activeElement: null, hidden: false };
  document.createElement = tag => {
    const node = new InteractiveNode(document, tag);
    if (tag === 'canvas') node.getContext = () => ({measureText:()=>({width:8}),setTransform(){},clearRect(){},setLineDash(){},beginPath(){},moveTo(){},lineTo(){},stroke(){},fillRect(){},fillText(){},save(){},translate(){},rotate(){},restore(){}});
    return node;
  };
  document.createDocumentFragment = () => new InteractiveNode(document, 'fragment', true);
  const docEvents = new InteractiveNode(document);
  document.addEventListener = docEvents.addEventListener.bind(docEvents);
  document.removeEventListener = docEvents.removeEventListener.bind(docEvents);
  const window = new InteractiveNode(document);
  window.requestAnimationFrame = callback => callback();
  window.cancelAnimationFrame = () => {}; document.defaultView = window;
  window.setTimeout = () => 1; window.clearTimeout = () => {};
  window.getSelection = () => ({ isCollapsed: true, removeAllRanges() {} });
  globalThis.window = window; globalThis.document = document;
  globalThis.getComputedStyle = () => ({ fontSize: '16px', lineHeight: '20px', fontWeight: '400', fontFamily: 'monospace' });
  const root = new InteractiveNode(document);
  const roles = new Map(['terminal', 'stage', 'viewport', 'size', 'dimensions', 'pan-toggle'].map(role => [role, new InteractiveNode(document, role === 'size' ? 'select' : 'div')]));
  root.querySelector = selector => roles.get(selector.slice(10, -1)) || null;
  const saved = {}, requests = []; let width = 84, height = 4, seq = 0;
  const lab = await createInkLab({ root, terminalAdapter: () => ({ write: (frame, done) => done(), font() {}, ligatures() {}, dispose() {} }), workbench: { loadProjectPreferences: async () => saved, saveProjectPreferences: (_, value) => Object.assign(saved, value) }, request: async message => {
    requests.push(message);
    if (message.op === 'catalog') return { stories: [{ id: 'demo', title: 'Demo', group: 'Demo', sizes: [{ name: 'default', columns: width, rows: height }], color: 'truecolor' }] };
    if (message.op === 'close') return {};
    if (message.op === 'scroll') await options.onScroll?.(message);
    width = message.columns || width; height = message.rows || height;
    return { version: 2, kind: 'full', seq: ++seq, width, height, terminal: {columns: width, rows: height, inline: options.inline || false, scrollable: options.inline || false}, cursor: null, status: null, styles: {}, rows: Array.from({ length: height }, () => [[0, Array(width).fill(' ')]]) };
  } });
  return { roles, lab, document, saved, requests, close: async () => { await lab.close(); globalThis.window = previous.window; globalThis.document = previous.document; globalThis.getComputedStyle = previous.style; } };
}

test('inline wheel input coalesces pending events and reverses without replaying the old direction', async () => {
  let release, first = true;
  const harness = await inkHarness({ inline: true, onScroll: () => {
    if (first) { first = false; return new Promise(resolve => { release = resolve; }); }
  } });
  try {
    const {roles, requests} = harness;
    const stage = roles.get('stage'), terminal = roles.get('terminal');
    terminal.contains = target => target === terminal;
    for (const deltaY of [100, 100, 100, -3, -2]) await stage.fire('wheel', {target:terminal, deltaY, deltaMode:1});
    assert.deepEqual(requests.filter(x => x.op === 'scroll').map(x => x.lines), [100]);
    release();
    for (let i = 0; i < 12; i++) await Promise.resolve();
    assert.deepEqual(requests.filter(x => x.op === 'scroll').map(x => x.lines), [100, -5]);
  } finally { release?.(); await harness.close(); }
});
