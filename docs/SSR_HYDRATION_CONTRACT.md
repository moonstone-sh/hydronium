# Hydronium SSR Hydration Contract & Islands Architecture

> **Status (2026-09-10): this describes the mechanism that actually
> ships.** Every wire-format sample below was produced by running the real
> `hydronium_dom.server.render_to_string` against real island VNodes, not
> written by hand. Where something is declared but not yet acted on, this
> document says so explicitly and points at the code.
>
> **This document was rewritten on 2026-09-10 because its previous version
> was wrong.** It specified `data-island` / `data-island-priority` /
> `data-island-props` HTML *attributes* on a wrapper element. That design
> was never implemented. The real implementation uses HTML **comment
> markers** plus a single JSON client-plan script tag, and has since the
> islands slice landed. The old version also carried a status banner
> claiming no client-side hydration runtime existed anywhere in the
> repository; that is likewise no longer true — see §5. Treat any other
> document still referencing `data-island*` attributes (e.g.
> `docs/HYDRONIUM_SSR_VERTICAL_SLICE_COMPLIANCE.md` §355, and the
> `examples/showcase/InteractiveIsland.luax` sample) as describing the
> abandoned design.

## 1. Core Principles

Hydronium uses an **Islands of Interactivity** architecture:

- The vast majority of a document (layouts, navigation, static articles,
  tables, footers) is server-rendered into pure, non-reactive HTML with
  zero client-side JavaScript or Lua overhead.
- Isolated interactive regions ("islands") are demarcated by **HTML
  comment markers** delimiting a *range* of sibling nodes.
- All island metadata — which module, which interpreter, what props, what
  hydration priority — lives in **one** JSON `<script>` tag per page, not
  spread across per-element attributes.
- A page that declares no client surface at all ships neither the plan tag
  nor any bootstrap reference. SSR-only pages stay byte-for-byte free of
  hydration plumbing.

---

## 2. Island Boundaries Are Ranges, Not Elements

An island is emitted by `hydronium_dom/server/init.lua`'s `ISLAND` branch
(the `node.kind == symbols.ISLAND` case, ~L434–L467) as a pair of comment
markers wrapping the island's rendered children:

```
<!--hy:i:<id>:<interpreter>-->  ...island children...  <!--hy:/i:<id>-->
```

- `<id>` is allocated by `next_island_id()` (~L55): a deterministic,
  tree-order-derived, versioned string of the form `hy:i1`, `hy:i2`, …
  It is **never** a pointer, random value, or timestamp — two renders of
  the same tree produce the same ids, which is what makes SSR output
  cacheable and diffable.
- `<interpreter>` is `lua` or `js`, taken from the island descriptor
  (`d.lua.island` / `d.js.island` / `d.lua.mount`).

### Why comment markers instead of attributes

This is the substantive design decision the previous version of this
document got wrong, and it is worth stating plainly: **the abstraction was
never `boundary = HTMLElement`.**

An attribute-based marker (`<section data-island="...">`) can only ever
describe a boundary that *is* a single element. That forces a wrapper
element to exist for every island, which in turn:

- injects layout-affecting DOM that the author did not write (a `<div>`
  inside a `<table>`, a `<span>` inside a flex row, an extra block box
  wherever CSS was counting children);
- cannot represent an island whose content is **text only**;
- cannot represent an island spanning **several sibling elements**.

A comment-marker range represents all three cases with no wrapper at all.
This is not a theoretical advantage — here is real output from a real
`render_to_string` call, one island containing three sibling elements and
one containing bare text:

```html
<main><h1>Static shell</h1><!--hy:i:hy:i1:js--><button>-</button><span>Count: 42</span><button>+</button><!--hy:/i:hy:i1--><!--hy:i:hy:i2:js-->text only, no element wrapper<!--hy:/i:hy:i2--></main>
```

Neither of those two islands is expressible as an attribute on a wrapper
element without inventing a wrapper element that the author never asked
for. `ClientBoundaryRegistry.elements(id)` accordingly returns *zero, one,
or many* element children (see
`docs/HYDRONIUM_CLIENT_BOUNDARY_REGISTRY.md`).

The cost of this choice is real and was paid once, visibly: comment
markers are nodes, so the client reconciler's hydration walk had to learn
to distinguish "discovery-only marker, skip it" from "unexpected node,
that's a mismatch". Before it did, every root-mounted page silently fell
back to a full remount. That is recorded in
`docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md` (~L489) and is handled today
by `dom/src/hydronium_dom/client/dom_bridge.js` (~L136) plus the
`boundaryNode` sentinel parameter threaded through
`Reconciler:hydrate` (see §4).

---

## 3. The Client Plan (`__HYDRONIUM_CLIENT_PLAN__`)

Island and script metadata is collected during the render into a single
`render_state.client_plan` table and emitted **once**, after the document
body, as:

```html
<script id="__HYDRONIUM_CLIENT_PLAN__" type="application/json">{"islands":[…],"scripts":[…],"version":"hydronium.client-plan.v1"}</script>
```

Real emitted plan, from the same render as the HTML above:

```json
{
  "islands": [
    {"hydrate":"visible","id":"hy:i1","interpreter":"js","module":"/static/counter.js","props":{"start":42},"root":false},
    {"hydrate":"load","id":"hy:i2","interpreter":"js","module":"/static/note.js","root":false}
  ],
  "scripts": {},
  "version": "hydronium.client-plan.v1"
}
```

### Island entry fields

| Field | Source | Meaning |
| :--- | :--- | :--- |
| `id` | `next_island_id()` | Matches the comment markers in the HTML. The join key between plan and DOM. |
| `interpreter` | island descriptor | `"lua"` or `"js"`. |
| `root` | `props.root == true` | True for `d.lua.mount` — a root-sized island covering the whole app. |
| `module` | `props.module` | Module specifier to load. **Must be an absolute path or full URL**, never `"./chart.js"` — a dynamic `import()` resolves relative specifiers against *the bootstrap's* URL, not the page's. |
| `mode` | `props.mode` | `"mount"` selects the module's `mount()` export; otherwise `hydrate()`. |
| `hydrate` | `props.hydrate or "load"` | Declared scheduling priority. **See the honesty note below.** |
| `props` | `props.props` | JSON-serializable initialization props. |

`scripts[]` entries (from `d.js.script`) carry `src`, `module`, `type`,
`strategy`, `integrity`, and `bindings`. A `d.js.script` node produces no
HTML output of its own — injection strategy is a client-plan concern.

Note the empty-table encoding: an empty `scripts` list serializes as `{}`,
not `[]`, because the serializer cannot distinguish an empty array from an
empty object in Lua. Consumers must tolerate both.

### Honesty note on `hydrate`

`hydrate` is **recorded, transported, and honored.** `bootstrap.js` and
`priority.js` (shared with `mount.js` so the vocabularies can't drift)
read this field per island: `"load"` still activates eagerly (unchanged
default), while `"visible"` (real `IntersectionObserver`) and `"idle"`
(real `requestIdleCallback`) genuinely defer both fetching the island's
module and mounting it until the trigger fires. `"interaction"` is not
yet a distinct scheduling mode -- treat it as reserved. This closed the
gap `docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md` previously described; that
document's own "No hydration policies beyond a stored string" line is
stale for the same reason and is corrected there.

---

## 4. State Transfer (`__HYDRONIUM_STATE__`)

Independently of the client plan, `render_to_string(vnode, { state = … })`
emits a deterministic JSON payload:

```html
<script id="__HYDRONIUM_STATE__" type="application/json">{"user":{"id":1}}</script>
```

Both script tags are suppressible (`options.suppress_state_script`,
`options.suppress_client_plan_script`), and the plan tag is only emitted
when the page actually declared at least one island or script.

### Security & determinism

The serializer is `dom/src/hydronium_dom/server/json.lua` (also exported
as `server.encode_state`). It is deliberately not a general-purpose JSON
library — it supports only `nil`, booleans, finite numbers, strings, and
acyclic tables with string keys or contiguous positive-integer keys, and
raises on anything else (cycles, `NaN`/`inf`, non-string object keys,
functions).

Its escaping is **stronger than "neutralize `</script>`"**, which is how
the previous version of this document described it. Rather than special-
casing that one sequence, it escapes every `<`, `>`, and `&` in a string
value unconditionally to the JSON escapes `\u003c`, `\u003e`, and
`\u0026`, plus U+2028/U+2029 to `\u2028`/`\u2029` (which are newlines to a
JS parser but not to a JSON one). Consequently no string value can
terminate the raw-text `<script>` element or open an HTML comment,
regardless of how a given consumer handles HTML parser edge cases. Real
output:

```
input:  { s = "</script><img src=x onerror=alert(1)>", amp = "a&b" }
output: {"amp":"a\u0026b","s":"\u003c/script\u003e\u003cimg src=x onerror=alert(1)\u003e"}
```

Object keys are sorted with `table.sort` before emission, so the same
state always produces byte-identical JSON — required for deterministic
hashing and caching.

---

## 5. Client-Side Consumption

The client side is real and shipped, under
`dom/src/hydronium_dom/client/`:

- **`boundary_registry.js`** owns *all* marker parsing. Nothing else in
  the codebase reads `hy:i:` strings. It finds a boundary's markers with a
  `TreeWalker` over `NodeFilter.SHOW_COMMENT`, and exposes semantic
  operations: `discover(root, id)`, `elements(id)`, `claim(id, owner)` /
  `release(id, owner)`, and `generation(id)` / `advanceGeneration(id)` /
  `isStale(id, gen)`.

  Its failure modes are deliberate: a boundary that is genuinely absent
  returns `null` (the SSR segment may simply not have arrived), while a
  start marker with no matching end, or a duplicate start for one id,
  **throws** — malformed SSR output fails loudly instead of silently
  patching an arbitrary nearby range. `claim()` throws on a conflicting
  owner, so two patch mechanisms cannot both believe they own a boundary.

- **`bootstrap.js`** reads `__HYDRONIUM_CLIENT_PLAN__`, and for each
  `interpreter: "js"` island dynamically `import()`s `island.module` and
  calls its `hydrate(context)` export (or `mount(context)` when
  `mode: "mount"`), where `context = { root, props }` and `root` is the
  single element child or the array of them. It claims ownership of every
  island it activates. `interpreter: "lua"` islands are counted and
  skipped — this file contains no import of any Lua/WASM runtime on any
  code path.

### Reconciliation and mismatch recovery

`Reconciler:hydrate` / `Reconciler:hydrateRoot`
(`core/src/hydronium/core/reconciler.lua`, ~L481–L660) claim existing
server DOM rather than rebuilding it: matching elements are adopted in
place, props are hydrated, reactive bindings and refs are attached, and
matching text nodes are left untouched.

Its `boundaryNode` parameter is the comment-marker mechanism surfacing in
the reconciler: it is a sentinel the walk must never claim or step past —
the closing marker of a partial-island hydration range — and is `nil` for
whole-container hydration such as `d.lua.mount`'s root case.

On mismatch, recovery is **per-vnode, not per-island**. The previous
version of this document claimed the reconciler "discards the corrupted
server DOM subtree for that specific island" and remounts the whole
component; it does not. It reports via the host hook
`host.hydrationMismatch({ reason, vnode, domNode })` and falls back to
`self:mount` for that **one** vnode, through the same six-method Host
contract every ordinary mount uses — there is no second DOM-patching
mechanism. Real reason codes emitted today:

| Reason | Condition |
| :--- | :--- |
| `element_mismatch` | No node, hit the boundary sentinel, not an element, or wrong tag name. |
| `text_mismatch` | Expected a text node, found something else (or ran out). |
| `extra_child` | Live children remained after the vnode's children were consumed; they are removed. |
| `extra_root_child` | Same, at the hydration root. |

Whether a mismatch is logged, counted, or thrown is the **host's**
decision — the reconciler only reports. A host that provides no
`hydrationMismatch` hook still gets correct (silently repaired) DOM.

---

## 6. Known Gaps

Stated here so no reader mistakes this document for a completeness claim:

- **`hydrate` priorities are honored for `"load"`/`"visible"`/`"idle"`**
  (§3.x, "Honesty note on `hydrate`"); `"interaction"` is reserved and not
  yet a distinct scheduling mode.
- **No streaming Suspense.** Suspense isolates writes into an in-memory
  buffer; it is not a chunked-transfer segment sent early and replaced
  later. There is no client-side out-of-order segment patcher, and
  streaming boundary IDs distinct from island IDs do not exist.
- **`interpreter: "lua"` islands are not activated by `bootstrap.js`.**
  The published "Hydronium in WASM" proof hydrates a Lua island directly,
  deliberately not coupled to this bootstrap.
- **`boundary_registry` implements only boundary kind `"island"`.**
  `"suspense"` and states like `"declared"`/`"pending"` are intentionally
  unimplemented — no real consumer exists yet to prove their shape.

## 7. Related Documents

- `docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md` — the islands/Suspense slice,
  including the verified end-to-end run against `examples/meteorite_ssr`.
- `docs/HYDRONIUM_CLIENT_BOUNDARY_REGISTRY.md` — why marker parsing was
  extracted from two real duplicated consumers, and the exact API surface.
- `docs/HYDRONIUM_BALLAD_ARCHITECTURE_PLAN.md` — the real bundling
  pipeline, and the hydration-remount bug comment markers caused.
