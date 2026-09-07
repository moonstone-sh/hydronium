# Hydronium `.luax` DX — Current State Audit (Ground Truth)

**Status: this document replaces a prior version of the same name that
self-certified claims which direct testing disproves.** Everything below was
verified by reading the live code paths, running the real test suites
(`luajit tests/runner.lua`, `bash tests/luax/run_nvim_tests.sh`), and running
headless Neovim by hand — not by reading other docs. Where a claim could not
be verified this way, it's marked as such rather than asserted.

Audit date: 2026-09-06.

---

## 1. Executive summary

Hydronium `.luax` has substantial real infrastructure: a working modal
lexer/parser/compiler, a real (not scaffolded) Tree-sitter grammar with a
compiled parser and four query files, a real LuaLS virtual-source plugin, a
generated DOM type catalog, and a functioning (now fixed) Neovim
integration. **But the previous `docs/LUAX_DX_COMPLIANCE_V2.md` and
`LUAX_DX_CURRENT_STATE.md` certified several specific claims as "VERIFIED" /
"Production Ready" that were false when checked against the actual code and
by actually running the test suites they cited.** The two most important
corrections:

1. **The global-pollution claim was false.** `__luax_intrinsic` was not
   "eradicated" — it was the literal, tested, live projection target for
   every bare intrinsic tag (`<button>`, `<div>`, …) in the LuaLS
   virtual-source path, and it had **no reachable type declaration anywhere
   LuaLS could see it** (the one place it was typed, `dom_typing.lua`, is
   dead code — generated only inside its own test, then deleted). This has
   been fixed in this session (see §4).
2. **The Neovim "Production Ready" claim was untested against the actual
   documented install path.** The shipped headless test script
   (`tests/luax/run_nvim_tests.sh`) does pass, but it only adds the
   **hydronium repo root** to `rtp` — not `extra/nvim`, the directory the
   docs and compliance cert say is the installable plugin
   (`{"moonstone/hydronium.nvim", ...}`). A user who installs only
   `extra/nvim` (the real-world scenario for anyone who isn't developing
   inside this repo) got filetype detection but **no tree-sitter parser and
   no queries**, because those live at the repo root, not inside
   `extra/nvim/`. This has also been fixed in this session (see §5).

## 2. What "311/311 passing" actually verifies

`luajit tests/runner.lua` does run 311 real specs across 24 suites and they
do all pass — this part of the prior claim is true. What it does **not**
verify is DX correctness: several of those specs directly assert the
presence of the architecture the compliance doc claimed was removed (e.g.
`tests/luax/dom_typing_spec.lua:108` asserted `__luax_intrinsic = {}` exists;
`tests/luax/luals_plugin_spec.lua` asserted the live virtual-lowering path
emits `__luax_intrinsic.button(...)`, before this session's fix). A green
test suite here means "the code does what its own tests say it does," which
is a much weaker claim than "the DX architecture matches the docs."
Separately, headless Neovim tests are **not** part of this 311 — they're a
separate script that has to be run explicitly and wasn't wired into any
described CI path.

## 3. The two tag systems, precisely

`.luax` supports two forms of intrinsic tag, and they take genuinely
different code paths:

```lua
<button onClick={fn}>Save</button>       -- "bare" tag
<d.button onClick={fn}>Save</d.button>   -- "lexical" tag (require("hydronium.dom").d)
```

**Lexical (`d.button`)**: the tag name is an ordinary `JSXMemberExpression`.
The compiler (`src/hydronium/luax/compiler/init.lua`) treats it as an
expression and emits it as-is — `d.button(...)` for direct/virtual modes,
`H.h(d.button, {...})` for the Hydronium runtime factory. `d` is a real,
immutable runtime table (`src/hydronium/dom/init.lua`) whose fields are
callable descriptors (`$$typeof = symbols.INTRINSIC`, `tag = "button"`,
`host = "dom"`) unwrapped back to a plain string tag by
`core/element.lua`/`server/init.lua`/`core/reconciler.lua` before any
DOM/SSR operation. It is fully and correctly typed
(`types/dom/init.d.lua`'s `HydroniumDOMDescriptors` class, now with a
catch-all `[string]` fallback field added this session — see §4.2). This
path has **zero global pollution** and is the one place the "lexical tags"
half of the mission's core question is already correctly implemented.

**Bare (`<button>`)**: the tag name is a plain `Identifier`. Whether it's
"intrinsic" (vs. a capitalized component) is decided by
`src/hydronium/luax/environment.lua`'s `Environment:is_intrinsic`, which for
the default/universal environment (the one every project gets unless it
explicitly registers another) falls back to a **pure naming-convention
heuristic**: lowercase-first-char or hyphenated → intrinsic, dotted → never
intrinsic, otherwise → component. It does **not** consult the actual DOM tag
catalog. This means `<zzz>` is classified "intrinsic" exactly like
`<button>` — the classification has no real per-host contract behind it in
the default case. The *chosen environment itself* is process-global mutable
state (`environment.set_current`), not a per-file lexical declaration — so
bare-tag resolution currently has **no explicit semantic source** at all,
which is exactly the failure mode the design brief calls out and asks to
avoid.

**Every example under `examples/`, and every component fixture under
`tests/fixtures/`, uses the bare form exclusively.** There are zero
occurrences of `<d.` in any example or fixture file. The lexical form is
real and unit-tested at the runtime-descriptor level
(`tests/core/dom_descriptors_spec.lua`) but is not dogfooded in a single
real `.luax` file in this repository.

## 4. Fixes made this session

### 4.1 Bare intrinsic tags now project to a real, typed global

**Before**: `compiler/init.lua`'s `emit_jsx_element` (virtual_luals mode,
which is what the live LuaLS plugin — `src/hydronium/luax/luals/init.lua` →
`hydronium.luax.plugin` → `compiler.compile(..., {virtual_luals=true})` —
actually calls on every keystroke) emitted `__luax_intrinsic.button(...)`
for bare tags. `__luax_intrinsic` was declared as a LuaLS-known global only
via `.luarc.json`'s `diagnostics.globals` list, which suppresses the
"undefined global" warning but supplies **no type** — so `<button
onClick={...}>`'s `onClick` handler parameter had no inferable event type,
and `<button |` had nothing to complete against. The one file that *did*
type `__luax_intrinsic` (`src/hydronium/luax/dom_typing.lua`, as
`__luax_intrinsic_catalog`) is dead code: `write_definitions_file` is called
only by its own test, which deletes the output file immediately after
asserting on it; it is never on `workspace.library` and LuaLS never sees it.
A second class, `LuaxIntrinsics` in `types/dom/intrinsics.d.lua`, declares
the same shape but is never assigned to any variable — also orphaned. (Full
forensic detail in the background audit that fed this doc; both dead paths
are left in place as known cleanup debt rather than deleted, to keep this
session's change surface small — see §7.)

**After**: bare intrinsic tags now project to `d.<tag>(...)` — the same
real, typed, tested global the lexical form already uses
(`src/hydronium/luax/compiler/init.lua`, `emit_jsx_element`). This is not a
redesign, just pointing the existing virtual-source projection at type
information that actually exists and is reachable. `tests/luax/luals_plugin_spec.lua`
was updated to assert the new target and passes. Fragments have the matching
gap: `__luax_fragment` (emitted for `<>...</>` in virtual mode) was in the
same boat — untyped except in the same dead `dom_typing.lua` string. Added a
real declaration to `types/luax.d.lua` (mirrors the existing
`__luax_component`/`__luax_element` pattern already there) so it's now typed
too.

**Not fixed / left as-is intentionally**: `src/hydronium/luax/luals/virtual_source.lua`'s
`transform()` function (a separate, more sophisticated byte-perfect 1:1
lowerer) has its own dead branch (`transform_element`, never called) that
would have had the same `__luax_intrinsic` bug had it ever been wired up —
its actually-used `build_virtual()` path doesn't distinguish intrinsic vs.
component tags at all and would emit a bare unqualified global call like
`button{...}` for `<button>`. This function is not reachable from the live
`.luarc.json` plugin path today (confirmed: `luals/init.lua`'s `OnSetText`
calls `plugin_mod.virtual_lower`, not `virtual_source.transform`), so it's
inert, but it's a landmine if anyone rewires it later. Flagging here rather
than fixing now, since untangling which of the two virtual-lowering
implementations is "canonical" is itself part of the larger architecture
decision in §6, not a one-line fix.

**This fix was NOT re-verified against a real running `lua-language-server`
binary** (none was available in this environment) — it was verified by (a)
reading the type declarations to confirm `d`/`HydroniumDOMDescriptors` are
real, reachable, workspace-library-visible globals, and (b) confirming the
virtual-source output now references them. A real LuaLS completion/hover
check (mission's Gate item #5-#7) is still open — see §7.

### 4.2 `HydroniumDOMDescriptors` had no fallback index signature

The runtime `d` table (`src/hydronium/dom/init.lua`) creates a descriptor
for *any* tag name on demand via its `__index` metamethod — `d.strong`,
`d.mark`, `d.blockquote` etc. all work at runtime even though they aren't in
the ~150-tag `STANDARD_TAGS` list's cache (cache is just a perf
optimization; `__index` handles the rest). But the type declaration
(`types/dom/init.d.lua`'s `HydroniumDOMDescriptors` class) only explicitly
declares ~55 fields, with no catch-all. Before this session, referencing any
undeclared tag (through either `d.<tag>` or, now, the fixed bare-tag
projection) would have produced a false-positive "field does not exist"
diagnostic in LuaLS for real, valid tags. Added
`---@field [string] hydronium.Intrinsic<any, any>` as a fallback so
undeclared tags still type-check (permissively, as `any`/`any`) instead of
erroring, matching real runtime behavior. This was a prerequisite for §4.1's
fix to not make things worse for the ~100 tags outside the explicit list.

### 4.3 Neovim: `extra/nvim` is now actually self-contained

**Before**: `require("hydronium").setup()` (`extra/nvim/lua/hydronium/init.lua`)
registered the tree-sitter *language name* (`vim.treesitter.language.register`)
but never made the compiled parser (`parser/luax.so`) or queries
(`queries/luax/*.scm`) discoverable, and did no modern filetype registration
of its own. Those files live at the **hydronium repo root**, not inside
`extra/nvim/`. Verified with a headless Neovim run that put only
`extra/nvim` (absolute path, simulating a real plugin-manager install from
an unrelated cwd) on `rtp`: filetype detection failed (`nil`), tree-sitter
parser load failed ("No parser for language luax"), highlight query
compilation failed, and the health check reported 0 OK entries — a hard
0-for-4 on the exact headless assertions the (prior, false) compliance doc
claimed were "Production Ready".

**After**: `M.setup()` now (1) calls `vim.filetype.add({extension = {luax =
"luax"}})` directly, so filetype detection doesn't depend on which
`ftdetect/` file happened to get scanned, and (2) appends the project root
to `rtp` (via the same self-locating `debug.getinfo`/`nvim_get_runtime_file`
logic `get_root_dir()` already used, so this stays relocatable/zero-absolute-path)
whenever `parser/` or `queries/` aren't already reachable. Re-verified the
same way: with only `extra/nvim` (absolute path) on `rtp`, after
`setup()`, filetype detection, tree-sitter parser load, and highlight-query
discovery all succeed. The original `bash tests/luax/run_nvim_tests.sh` (repo
root on rtp) still passes 4/4.

**Not fixed**: `extra/nvim/ftdetect/luax.vim` still uses the old
`autocmd ... setfiletype luax` style rather than `vim.filetype.add` (the
repo-root `ftdetect/luax.lua` already uses the modern API; the two files are
redundant and drifted). Left as-is since `setup()` now calls the modern API
directly regardless, making this file's staleness low-stakes, but it should
be reconciled — see §7.

## 5. What's real vs. aspirational in the rest of the tooling

Verified by direct inspection (not by re-trusting other docs):

- **Tree-sitter grammar**: real. `tree-sitter-luax/grammar.js` (488 lines),
  generated `src/grammar.json`/`node-types.json`/`parser.c`, a compiled
  `luax.so`. Node types include `element_expression`, `opening_element`,
  `closing_element`, `self_closing_element`, `tag_expression`,
  `dotted_identifier`, `fragment`/`opening_fragment`/`closing_fragment`,
  `jsx_comment`. `queries/luax/{highlights,indents,folds,textobjects}.scm`
  all exist and are substantive (not stubs).
- **VS Code / TextMate**: real. `syntaxes/luax.tmLanguage.json` has distinct
  scopes for dotted vs. bare tags. `language-configuration.json` (brackets,
  auto-closing, indentation) exists at the repo root.
- **`Environment<I>`**: the mechanism (`environment.lua`) is real and
  genuinely consulted by the compiler, but the interface described in
  `docs/LUAX_TYPE_ENVIRONMENTS.md` (`get_attributes`, `get_event_type`,
  `get_vnode_factory`, plus `types/love2d/`, `types/roblox/`, `types/tui/`
  directories) does not exist in code at all — that doc is pure aspiration,
  not a description of what's shipped.
- **DOM type generation** (`tools/dom_generator/`): real, WebRef-driven,
  generates `types/dom/{events,html,svg,intrinsics}.d.lua`. `html.d.lua`
  (1207 lines) has genuinely rich per-element prop/event typing.
- **DOM type loading scope**: `.luarc.json` puts `types` (the whole `types/`
  tree, including all of `types/dom/`) on `workspace.library`
  unconditionally for every `.luax` file in the workspace, regardless of
  whether that project ever imports DOM. The mission's "a terminal-only
  project shouldn't index the whole browser DOM type universe" requirement
  is **not met** — this is real, structural, and not something this
  session's fixes touched (it needs either a Moonstone-level "only include
  `types/dom` if `hydronium.dom` is a declared dependency" mechanism, or
  splitting `.luarc.json` generation per-project, neither of which exists
  yet).

## 6. The lexical-vs-bare architecture decision (Gate A/B)

Based on the evidence above, not on the design brief's priors:

**Prefer lexical (`d.button`) as canonical.** It already has zero global
pollution, a real reachable type, and correctly-differentiated per-host
namespacing (`d.button` vs. a hypothetical `t.button` for a terminal host
never collide, because they're different Lua values, not entries in one
shared catalog). This matches Gate A's preference and the evidence supports
it cleanly — there's no architectural reason to prefer the bare form once
`d.<tag>` exists and works.

**Keep bare tags, but they are not currently "contextual" in the sense Gate
B requires.** Today's bare-tag resolution has no explicit per-file semantic
source (§3) — it's a naming heuristic over whatever the process-global
`current_environment` happens to be. This session's fix (§4.1) makes bare
tags *type-check* correctly by reusing `d`'s real type, but it does **not**
fix the deeper issue: a bare `<button>` in a file that has never required
`hydronium.dom` still resolves against DOM types, silently, with no lexical
or declared trigger. Closing this gap properly is language-design work
(likely: require an explicit per-file `---@luax environment dom` pragma or
equivalent, threaded through `environment.lua`, the compiler, and the LuaLS
virtual-source projection) that touches the lexer/parser/compiler/tests
broadly enough that it doesn't belong in the same session as the audit —
see §7 for how this is scoped.

## 7. Punch list — what's fixed vs. what's still open

**Fixed and verified this session:**
- Bare intrinsic tags project to a real, typed global (`d.<tag>`) instead of
  an untyped placeholder (`__luax_intrinsic`) in the live LuaLS path.
- `__luax_fragment` is now typed (`types/luax.d.lua`).
- `HydroniumDOMDescriptors` has a fallback index signature so undeclared
  tags don't false-positive as type errors.
- `extra/nvim`'s `setup()` makes the plugin actually self-contained
  (filetype detection + tree-sitter parser + queries) when installed
  standalone by a plugin manager, verified via headless Neovim from an
  unrelated cwd with an absolute path.
- All 311 Lua specs and all 4 headless-Neovim specs still pass after the
  above.

**Confirmed real but not touched this session:**
- Tree-sitter grammar, queries, TextMate grammar, DOM type generator
  pipeline — all genuinely implemented, not scaffolding.

**Confirmed false or unmet, still open:**
- Bare-tag resolution still has no explicit per-file semantic source
  (§6) — the core "must have an explicit semantic source" requirement from
  the design brief's Part III is not met.
- DOM types load unconditionally into every workspace regardless of usage
  (§5) — the "don't index the whole DOM for a terminal-only project"
  requirement is not met.
- No real end-to-end LuaLS completion/hover/rename test was run against an
  actual `lua-language-server` binary in this session (none was available)
  — the fixes in §4 are verified by type-declaration reachability, not by a
  live LSP transcript. This is the single most important remaining
  verification gap before trusting completion/hover/event-inference claims.
- `src/hydronium/luax/luals/virtual_source.lua`'s alternate lowering path
  has its own latent bug for bare tags (§4.1) and duplicates
  `compiler/init.lua`'s responsibility — the two should be reconciled or one
  deleted.
- The dead `dom_typing.lua` `__luax_intrinsic`/`__luax_fragment` generation
  and the orphaned `types/dom/intrinsics.d.lua` `LuaxIntrinsics` class are
  still present, contradicting each other and this doc's own history —
  cleanup, not urgent, but worth removing to stop future confusion.
- No example `.luax` file uses the lexical form despite it being the
  recommended canonical syntax (§3/§6) — no migration has actually happened
  in example code.
- The rest of the doc set (`LUAX_DX_ARCHITECTURE.md`, `LUAX_TAG_SEMANTICS.md`,
  `LUAX_LUALS_ARCHITECTURE.md`, `LUAX_TREE_SITTER.md`, `LUAX_NVIM.md`,
  `LUAX_VSCODE.md`, `LUAX_EDITOR_PERFORMANCE.md`, `LUAX_DX_COMPLIANCE_V2.md`,
  `HYDRONIUM_CURRENT_STATE_AUDIT.md`) still contains claims not verified
  against code in this pass, and at least two of the doc families
  (the "zero pollution" docs vs. `HYDRONIUM_CURRENT_STATE_AUDIT.md`, which
  describes `__luax_intrinsic` as the intentional, hardened mechanism)
  **contradict each other**, independent of what the code does. `LUAX_DX_COMPLIANCE_V2.md`
  has a correction notice pointing here (see that file) but has not been
  fully rewritten.
- VS Code support was not exercised in an actual VS Code instance; only the
  TextMate/language-configuration files were read.
- No performance benchmarking (Part XXIII of the design brief) was
  attempted this session.

**Bottom line**: this repo has more real infrastructure than a skeptical
read of the code alone would suggest, but meaningfully less than the
existing docs claimed, and the gap wasn't cosmetic — it was hiding a
concrete, fixable bug (bare-tag completion had nothing to complete against).
Treat any remaining "VERIFIED"/"Production Ready" language elsewhere in
`docs/` as unconfirmed until re-checked the same way this document was
produced: read the live code path, run the real test, don't take the doc's
word for it.

---

## 8. Session 2 (same day): a live `rename` request was corrupting files

While implementing §4's fixes, a further, more serious bug was found and
fixed: **`textDocument/rename` on a lexically-imported `d` (`local d =
require("hydronium.dom")`) destroyed the entire buffer** whenever `<d.tag>`
was used more than once with children, e.g. renaming `d` in

```lua
local d = require("hydronium.dom")

return <d.main>
  <d.h1>Hello</d.h1>
  <d.button onClick={function() end}>Save</d.button>
</d.main>
```

produced (verified via real headless Neovim + real `lua-language-server`,
applying the actual `WorkspaceEdit`):

```
local dom2 = require("hydronium.dom")

return <dom2dom2dom2
```

This was not a hypothetical — it reproduces on the first realistic
multi-tag lexical example tried. Root-caused and fixed in three layers,
each verified independently before moving to the next:

### 8.1 The live LuaLS path was never byte-aligned in the first place

The actual wiring (`.luarc.json` → `src/hydronium/luax/luals/init.lua` →
`hydronium.luax.plugin` → `compiler.compile(source, {virtual_luals=true})`)
used the compiler's normal `CodeEmitter`, which builds a *fresh* nested
function-call rewrite (flattening children into varargs, e.g. `<d.main>`
with two children became `d.main(nil, d.h1(...), d.button(...))` on
completely different lines/columns than the source). Despite `docs/LUAX_DX_COMPLIANCE_V2.md`'s
headline claim of "exact 1:1 byte-aligned virtual source lowering," this
path never attempted byte alignment at all — it only happened to *look*
aligned for the narrow case the old tests covered (a single self-closing
tag with no children, where the rewrite happens to be the same length by
coincidence).

A second, separate, genuinely byte-preserving implementation already
existed (`src/hydronium/luax/luals/virtual_source.lua`, an in-place
byte-array rewriter) but was **completely dead code** — nothing in the live
plugin path called it; it was only ever exercised by narrow unit tests
covering single dotted-tag transforms.

**Fix**: `src/hydronium/luax/plugin.lua`'s `virtual_lower` now calls
`virtual_source.transform` instead of `compiler.compile(...,
{virtual_luals=true})`. This is a real design trade-off, not a strict
upgrade: `virtual_source.transform` cannot inject a type-qualifying prefix
(like `d.`) in front of a *bare* tag without changing that byte range's
length, which would defeat byte alignment again. So in this path, bare
intrinsic tags (`<button>`) now project to a literal, unqualified
`button{...}` call — untyped from LuaLS's point of view (an honest
"undefined global" rather than a fake type) — while lexical tags
(`<d.button>`) get full, byte-accurate typing *and* correct rename/reference
positions, because reusing already-present source text (`d.button`) needs no
extra characters. **This is additional, concrete evidence for the Gate A/B
conclusion already in this doc: lexical tags are not just architecturally
preferable, they are the only form that can be both correctly typed and
positionally accurate in the current LuaLS plugin protocol.** `tests/luax/luals_plugin_spec.lua`
was rewritten to assert the new (correct) direct-call, byte-length-preserving
shape.

### 8.2 The parser's own byte offsets were wrong for the trailing edge of most tokens

Fixing 8.1 exposed a **lexer/parser bug** that had nothing to do with the
LSP plugin: `ast.create_loc(...)` calls throughout `src/hydronium/luax/parser.lua`
computed a node's *end* byte offset as `end_tok.pos` — a token's *start*
offset — for every token type except `JSX_TEXT` (the only one that ever set
`end_pos`). For a multi-character end token (e.g. a string-literal attribute
value), this silently truncated the recorded range to just past the token's
first character. Reproduced concretely: `<button id="my-btn" disabled ...>`
lowered to `button{id=",y-btn" d,sabled ...}` — attribute text corrupted
mid-word, because `virtual_source.lua`'s byte-accurate overwrite logic
trusted a range that didn't actually cover the whole attribute.

**Fix**: `src/hydronium/luax/lexer.lua`'s `M.tokenize` now backfills
`tok.end_pos` for every token (`lexer.pos - 1`, i.e. where the lexer ended
up right after fully consuming the token) when a token constructor didn't
already set one. `src/hydronium/luax/parser.lua`'s twelve affected
`ast.create_loc` end-boundary computations were changed from `end_tok.pos`
to `end_tok.end_pos or end_tok.pos` (the four sites that already had a
manual `+1`/`+#value-1` workaround were left untouched). Verified by
re-running the exact corrupted case above (clean output afterward) and the
full suite (no regressions).

### 8.3 JSX has no comma between children; the virtual Lua table constructor needs one

Still not enough: `<d.main><d.h1>Hello</d.h1><d.button>Save</d.button></d.main>`
lowered to `d.main{ d.h1{"   "} d.button{...} }` — **missing the comma**
between the two children, since JSX has no such separator but a Lua table
constructor requires one. This is invalid Lua that `load()` rejects — but
LuaLS's own parser doesn't fail loudly on it; it silently recovers by
folding the malformed span into one oversized reference, which is what
produced the garbled multi-line rename/reference ranges. This bug was never
caught by any prior test because `virtual_source.lua` was dead code
exercised only by single-tag, no-sibling-children unit tests.

**Fix**: `virtual_source.lua`'s `build_virtual()` now finds every pair of
consecutive "significant" children (skipping comments and whitespace-only
text) within each element/fragment and inserts a `,` into the first
available non-newline byte of the gap between them — ordinary indentation
whitespace in real-world formatted code, so it essentially never has to
consume anything meaningful (the one known residual gap: `<a/><b/>` with
*zero* whitespace between siblings has no spare byte to use). Verified with
`loadstring()` on the transformed output (now valid Lua) and the full suite.

### 8.4 `OnSetText`'s single "first-diff..last-diff" hunk confused LuaLS's reference remapping

With 8.1–8.3 fixed, the virtual document was finally valid, byte-aligned
Lua — and rename *still* didn't fully work. Control experiment: the exact
same code shape (`d.main{ d.h1{"Hello"}, d.button{...} }`), saved as a plain
`.lua` file (no plugin involved at all), gave LuaLS's `textDocument/references`
four clean, single-character ranges. The identical content delivered through
this plugin's `OnSetText` gave one correct range (outside the diff) plus
three garbled/overlapping ones (inside it). The variable was `compute_diff`
(in both `plugin.lua` and `luals/init.lua`): it found only the common
prefix and common suffix and returned **one** hunk spanning everything
in between — for a JSX-heavy file that's nearly the whole document, so
almost every unchanged identifier (every occurrence of `d`) ends up
*inside* that one hunk rather than outside it. LuaLS's position-remapping
for occurrences inside a diff hunk is evidently unreliable in a way it
isn't for positions outside any hunk.

**Fix**: replaced the single-hunk prefix/suffix diff with a proper
multi-hunk, per-changed-byte-run diff (cheap and exact here because
`virtual_source.transform` guarantees `#orig == #virt`, so no LCS/alignment
is needed — a linear scan finds every contiguous run of differing bytes and
emits one small hunk per run). `luals/init.lua` now reuses
`hydronium.luax.plugin.compute_diff` instead of duplicating its own copy.

**Result, verified via real headless Neovim + real `lua-language-server`**:
renaming `d` → `dom2` on the reproduction case above now correctly updates
all three *opening*-tag occurrences (`<dom2.main>`, `<dom2.h1>`,
`<dom2.button>`). It does **not** update the three closing tags
(`</d.h1>`, `</d.button>`, `</d.main>` are left unchanged) — this is
expected, not a remaining bug in the same class: closing-tag text is
blanked out to padding in the virtual document (there is no identifier
there for LuaLS to rename), so keeping a closing tag's name mirrored to its
opening tag is a **Tree-sitter "linked editing" problem**
(`textDocument/linkedEditingRange`, or an editor-side auto-rename-tag
integration against `tree-sitter-luax`), not something semantic LSP rename
can or should do. This is not implemented yet — see the punch list below.

### Updated punch list (supersedes the equivalent bullets in §7)

- Rename/references on lexical tags (`<d.button>`) now work correctly
  through the real LuaLS plugin path for opening-tag occurrences — verified
  with real `WorkspaceEdit` application, not just a claim.
- Closing tags are not kept in sync by *LSP* rename (renaming the `d` in
  `local d = require(...)` still leaves closing tags' `d` untouched — see
  §8.4). **Partially closed by §9 below**: editing a tag's own name directly
  (not the namespace alias) now keeps its opening/closing pair in sync via
  tree-sitter-based linked editing, which is the far more common editing
  action (changing `<div>` to `<span>`, not renaming an import alias).
- Bare intrinsic tags (`<button>`) are now honestly untyped in the live
  LuaLS path (a plain, unqualified identifier call) rather than fake-typed
  against `__luax_intrinsic` (dangling) or `d` (misleading, since no `d` may
  even be in scope) — this is a real regression in bare-tag *typing*
  relative to §4.1's fix earlier in this document, traded for correctness
  (no more file corruption on rename). §4.1's `d.<tag>` fallback remains
  intact in `compiler.compile`'s `virtual_luals` mode and in `bin/luax
  check`'s lint (a separate, offline consumer unaffected by this section),
  so the real compiled runtime output and the CLI lint are unaffected by
  this trade-off — only the live, interactive LuaLS typing of bare tags is.
- `docs/LUAX_DX_COMPLIANCE_V2.md`'s "exact 1:1 byte-aligned virtual source
  lowering" claim (Amendment 2/Q52-60) was false for the code path actually
  wired into `.luarc.json`; it was only ever true of the dead
  `virtual_source.lua` path, which is now the live one.
- This entire investigation is additional, concrete, reproduced evidence
  for preferring lexical tags as canonical (§6): they are the only tag form
  that gets both correct typing *and* correct position-sensitive LSP
  features (rename, references) in the current plugin architecture.

---

## 9. Tree-sitter "linked editing" (tag auto-close / auto-rename) via `nvim-ts-autotag`

Per the design brief's Part XX (#82: "test compatibility with existing
ecosystem [tag-editing] plugins... only build custom functionality where
needed") — no custom tag-editing machinery was written. `nvim-ts-autotag`
(a real, widely-used Neovim plugin, already present as a peer dependency in
the environment this was built in) has an officially documented extension
API (its README's "Extending the default config" section) for registering
brand-new languages: a per-filetype config of **tree-sitter node-type
names** describing what an opening tag, closing tag, tag name, and whole
element look like. tree-sitter-luax's actual node shapes (verified via a
real parse) slot directly in:

```
(opening_element name: (tag_expression (dotted_identifier object: (identifier) property: (identifier))))
```

```lua
TagConfigs:add(FiletypeConfig.new("luax", {
  start_tag_pattern      = { "opening_element" },
  start_name_tag_pattern = { "tag_expression" },
  end_tag_pattern        = { "closing_element" },
  end_name_tag_pattern   = { "tag_expression" },
  close_tag_pattern      = { "closing_element" },
  close_name_tag_pattern = { "tag_expression" },
  element_tag            = { "element_expression" },
  skip_tag_pattern       = { "img", "input", "br", ... }, -- void-ish tags
}))
```

Because `tag_expression`'s own source text is used as the tag name (not a
sub-field), this works identically for bare (`<button>`) and lexical/dotted
(`<d.button>`) tags — no special-casing needed. Implemented in
`extra/nvim/lua/hydronium/init.lua` as `M.setup_autotag(bufnr)`, called from
`M.setup()` behind a new `opts.autotag` flag (default `true`) via a
`FileType luax` autocmd, so it activates automatically for anyone who
installs `hydronium.nvim` and happens to also have `nvim-ts-autotag` — it
no-ops safely (returns `false`) if that plugin isn't installed.

**A real upstream bug was found and worked around along the way**:
`nvim-ts-autotag.internal.attach()` has a not-yet-set-up fallback path that
does `local _, ts_configs = pcall(require, "nvim-treesitter.configs")` and
then `if not ts_configs then M.setup(...) end` — but `ts_configs` here is
`pcall`'s *second* return value, which is the required module on success or
an **error string** on failure, not a boolean. Since a modern
`nvim-treesitter` may not ship the legacy `nvim-treesitter.configs` module
at all, that `require` fails, `ts_configs` becomes a truthy error string,
the fallback's own `M.setup()` call is skipped, and the very next line calls
`.get_module` on that string — an error, silently swallowed because our own
call into `attach()` is itself `pcall`'d. This only bites if
`nvim-ts-autotag`'s own `.setup()` hasn't run yet by the time a `.luax`
buffer first triggers our attach call (real-world setups almost always call
it during startup already, which is why this wasn't caught by casual
interactive testing — it only surfaced when testing `setup_autotag()` in
isolation). Worked around by having `M.setup_autotag()` call
`require("nvim-ts-autotag").setup({})` itself first (harmless/idempotent if
something else already did) before calling `attach()`, rather than trusting
that fallback path.

**Verified for real**, both via `tests/luax/nvim/test_headless.lua` (Test 5,
calling `nvim-ts-autotag.internal.close_tag()`/`rename_tag()` directly
against real tree-sitter-luax-parsed buffers — feeding raw insert-mode
keystrokes through `nvim_feedkeys` was unreliable specifically under
Neovim's `-l` headless-script execution mode, so the test drives the same
functions those keymaps call instead) and via actual interactive editing
through the real user Neovim config:
- `<div` + typing `>` → `<div></div>` (auto-close).
- Editing `<div>` → `<span>` and leaving insert mode → `</span>` follows.
- Editing `<d.button>` → `<d.span>` → `</d.span>` follows (dotted tags work
  identically to bare ones).
- Nested elements: renaming an inner tag only updates its own pair, not an
  enclosing one.
- Attribute-bearing tags: renaming works correctly with attributes present
  on the opening tag.
- Self-closing tags (`<input ... />`) do **not** get a closing tag
  auto-inserted (correctly excluded, since `self_closing_element` is a
  different node type than `opening_element` and isn't in
  `start_tag_pattern`).

This is complementary to, not a replacement for, §8's LSP-rename fix: LSP
rename handles renaming the **namespace alias** (`d` in
`local d = require(...)`) across all its lexical uses; this handles keeping
an individual **tag's own name** in sync between its opening and closing
occurrence as you edit it directly — the more common "auto rename tag" IDE
action, and the specific thing "tree-sitter linked editing" usually refers
to.
