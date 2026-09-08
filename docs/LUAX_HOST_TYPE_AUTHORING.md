# Typing a LUAX host's intrinsics: the actual pipeline

**Looking for how to type your own app's component props** (`<UserProfile
name="..." />`), not a new host's intrinsic tags? See
`docs/LUAX_COMPONENT_TYPING.md` instead — that's the common case, it's
simpler than everything below, and this doc deliberately doesn't cover it.

This follows this repo's own rule (`CLAUDE.md`'s "Trust issue in `docs/`"
section): say what was verified against real, running code, and say
plainly what wasn't. Nothing here should be read as "the only way to do
this" unless it's backed by a citation to the actual source.

## The question this answers

`<d.button>` (DOM) gets real LuaLS completion and hover on its props.
Does a new host — `<ink.Box>` (terminal), or whatever comes after it —
need special compiler support to get the same treatment? **No.** This doc
is the process for adding it to any host, using DOM (already done, large)
and `hydronium-ink` (done as part of this doc landing, small) as the two
real, working examples.

## The load-bearing fact: the compiler already doesn't care which host you are

Every dotted JSX tag — `<d.button>`, `<ink.Box>`, `<UI.Card>` — is lowered
by the exact same code path,
`luax/src/hydronium_luax/luals/virtual_source.lua`'s `transform_element()`
(~line 210–240). For any `JSXMemberExpression` name node, it always
projects to `__luax_component(<the dotted expression>, { ... })` — there
is no branch anywhere checking for `d`, `"dom"`, or any host string. Read
the function yourself before assuming otherwise; the `is_intrinsic`
special-casing that exists (`__luax_intrinsic.<tag>({...})`) applies only
to **bare, unprefixed** tags (`<button>`), a different and separate
mechanism (see "Bare tags" below) — not to dotted ones.

So `d.button`'s completion is not a compiler feature. It comes entirely
from `d` having a real, known LuaCATS type at the point LuaLS evaluates
`d.button` as an ordinary Lua expression. Giving `ink.Box` the same
treatment means giving `ink` (or whatever local holds
`require("hydronium_ink")`) a real type — nothing else.

## Two tiers, one shared foundation

Both tiers build on the same host-agnostic types in
`luax/types/luax.d.lua`: `LuaxElement`, `LuaxNode`,
`hydronium.Intrinsic<P, H>` (an intrinsic descriptor: callable, carrying
`tag`/`host`, typed by its props `P` and host tag `H`), and
`hydronium.ElementType<P, H>`. These are **hand-owned, framework-level,
and not generated** — see "Why `luax/types/luax.d.lua` is hand-owned, not
generated" below for why that's stated this bluntly.

### Tier 1 — hand-authored catalog (small hosts: `ink` today)

Annotate the host's own real runtime module directly. No ambient file, no
`workspace.library` entry, no codegen — LuaLS already infers types from
real project source, so this is the entire pipeline:

```lua
---@class HydroniumInkBoxProps
---@field flexDirection? "row"|"column"
-- ... one @field per prop ...

---@class HydroniumInkDescriptors
---@field Box hydronium.Intrinsic<HydroniumInkBoxProps, "terminal"> | fun(props?: HydroniumInkBoxProps, ...: any): LuaxElement
---@field Text hydronium.Intrinsic<HydroniumInkTextProps, "terminal"> | fun(props?: HydroniumInkTextProps, ...: any): LuaxElement
---@field Newline hydronium.Intrinsic<{}, "terminal"> | fun(props?: {}, ...: any): LuaxElement

---@type HydroniumInkDescriptors
local ink = {
  Box = create_descriptor("Box"),
  -- ... unchanged runtime code ...
}
```

**The `| fun(props?: P, ...): LuaxElement` union arm on each field is not
optional decoration — leaving it off breaks completion.** Confirmed the
hard way: a first pass at `ink/src/hydronium_ink/init.lua` declared each
field as the bare `hydronium.Intrinsic<P, H>` class alone, and a real
headless `lua_ls` `textDocument/completion` request against
`<ink.Box borderStyle="single" |>` came back with generic buffer/keyword
completion (Lua globals, already-typed identifiers), not
`HydroniumInkBoxProps`'s fields — `__luax_component`'s
`---@generic TProps @param component fun(props: TProps): any` can't bind
`TProps` from a class-typed value that merely carries an `@overload`;
adding the explicit plain-function union arm (matching
`dom/types/dom/init.d.lua`'s existing `d.button` declaration, which
already has this exact union and was the actual working reference this
was checked against) fixed it — the same completion request then
returned exactly `HydroniumInkBoxProps`'s remaining fields
(`justifyContent`, `flexGrow`, `flexShrink`, `flexWrap`, ... correctly
excluding `flexDirection`/`paddingX`, which were already present earlier
in that same attribute list).

That's it — `local ink = require("hydronium_ink")` in any consuming
`.luax` file now gets full completion on `ink.Box({ ... })`,
`ink.Text({ ... })`, etc., because `ink` itself now has a real type, and
`<ink.Box>` compiles through the same host-agnostic path described above.

Use this tier by default. Use it even if you expect to grow later — you
can always escalate to Tier 2 once a catalog actually gets big or
spec-derived enough to need it; starting there for three intrinsics would
be needless indirection.

### Tier 2 — spec-driven/generated catalog (large hosts: DOM today)

DOM's catalog is too large to hand-write (the HTML/SVG element and event
vocabularies, sourced from scraped WebIDL/webref spec data) and too
spec-derived to want inline in the runtime module. Its shape:

- `dom/types/dom/*.d.lua` — a `---@meta "dom"` ambient file (never
  executed, LuaLS-only) declaring a `HydroniumDOMDescriptors` class with
  a `[string] hydronium.Intrinsic<any, any>` catch-all plus per-tag
  overrides (`button`, `input`, `h1`, ...) typed against the generated
  `html.d.lua`/`svg.d.lua`/`events.d.lua`. It ALSO assigns a real
  top-level `d = dom` inside that meta file — since ambient files are
  read-only reference for LuaLS, that line is what types the **global**
  `d`, independent of any `require`, which is what makes DOM's *bare*
  intrinsic tags (see below) resolve too, not just `<d.button>`.
- `luax/tools/dom_generator/` (`webref_data.lua` + `init.lua`) —
  generates `dom/types/dom/{events,html,svg,intrinsics}.d.lua` from that
  spec data. Run it again only when DOM's own element/event vocabulary
  changes, not per-host.
- Consumers opt in via `.luarc.json`'s `workspace.library`, e.g.
  `examples/meteorite_ssr/.luarc.json`: `["../../luax/types",
  "../../dom/types", "../../dom/ambient-types", ...]`.

Reach for this only when Tier 1 genuinely doesn't fit — a catalog large
enough that hand-editing is impractical, or generated from an external
spec you don't want copy-pasted into hand-maintained Lua. Don't build a
generator for a host with three intrinsics; there usually isn't a
generic data source to generate *from* (DOM's is HTML/SVG's own spec;
most future hosts won't have an equivalent, and inventing a fake one to
match DOM's shape would be pure ceremony).

### Bare tags (`<button>`, unprefixed) — a separate mechanism, not part of this pipeline

Bare tags resolve through `env:is_intrinsic(tag_str)` (a naming heuristic
plus a process-global "current environment," see
`docs/LUAX_DX_CURRENT_STATE.md` and the environment-pragma tests) and the
`dom/ambient-types` opt-in global declarations — DOM-specific machinery
that predates this doc and is **not** being extended to new hosts here.
`CLAUDE.md` already calls lexical tags "the architecturally sound
canonical form" for a reason: they need no global state, no per-file
"which environment am I in" resolution, and (per this doc) already have a
real, working, host-agnostic typing story. New hosts should use lexical
tags (`<ink.Box>`) and Tier 1/Tier 2 typing above; extending bare-tag
support to a new host is a separate, larger decision this doc
deliberately doesn't make.

## Why `luax/types/luax.d.lua` is hand-owned, not generated

Until this doc landed, `luax/tools/dom_generator/init.lua` had a
`generate_luax()` function that (re-)wrote `types/luax.d.lua` from a
hardcoded string literal — despite living inside the *DOM* generator and
being listed as one of its outputs. Checked directly before removing it:
`generate_luax()`'s body never referenced `webref` (the DOM/SVG spec data
this generator otherwise depends on) at all — it was pure incidental
coupling, not derived from anything DOM-specific. Worse, diffing its
output against the real checked-in file at the time
(`generated == actual` → `false`, first divergence partway through the
file) showed it had drifted **stale**: `hydronium.Intrinsic`/
`hydronium.ElementType` — the very types both tiers above depend on —
appeared nowhere in what it would have (re-)written. Re-running the DOM
generator would have silently deleted them. It's been removed; see
`tools/dom_generator/init.lua`'s own doc comments at the removal site.
`luax/types/luax.d.lua` is maintained by hand, in place, going forward.

## Verification

Both real, not reasoned-about:

- A real headless LuaLS `textDocument/completion` request against a
  `.luax` file using `<ink.Box ...>`/`ink.Box({...})` returns real prop
  names (`flexDirection`, `justifyContent`, `flexGrow`, ...), matching how
  `CLAUDE.md` already verifies DOM's own `<d.|` completion the same way.
- `examples/ink_demo/demo.luax` (lexical tags) compiles and renders
  identically to `examples/ink_demo/run.lua` (the pre-existing plain-Lua
  version) — see that example's own directory for both, and
  `docs/HYDRONIUM_INK_TERMINAL_HOST.md` for the run.lua capture this was
  checked against.
