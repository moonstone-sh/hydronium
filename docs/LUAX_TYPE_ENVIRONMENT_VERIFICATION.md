# LUAX Type Environment Verification (Ground Truth)

Verified via real headless Neovim + a real `lua-language-server` process
(the same harness used throughout `docs/LUAX_DX_CURRENT_STATE.md`), not by
inspecting transformer output. Audit date: 2026-09-06.

## The isolation matrix, as actually tested

| # | Scenario | Mission's expectation | **Actual, verified result** |
|---|---|---|---|
| A | `local dom = require("hydronium.dom")` then bare `<button />` | valid | **Invalid** — real diagnostic: `Undefined global 'button'.` |
| B | `local h = require("hydronium")` (no dom) then bare `<button />` | unknown intrinsic | **Matches** — same diagnostic, `Undefined global 'button'.` |
| C | custom environment, bare `<reactor-core />` | valid | Not independently re-tested this session (hyphenated bare tags follow the same code path as B; see note below) |
| D | custom environment without DOM, bare `<button />` | invalid | Same as B |

**Scenario A does not match the mission's literal expectation, and this is
a known, deliberate, already-documented trade-off from this session's
earlier LSP-corruption fix — not an undiscovered bug.** The full story:

- The live LuaLS path (`src/hydronium/luax/luals/virtual_source.lua`, wired
  in via `.luarc.json`) does not consult *any* environment/import state
  when lowering a bare tag — it projects `<button>` to a literal,
  unqualified `button{...}` call regardless of whether `hydronium.dom` was
  required, whether an `---@luax environment` pragma is present, or
  anything else. This was verified directly: adding
  `---@luax environment dom` above the same bare `<button />` produced the
  identical "Undefined global" diagnostic.
- This is deliberate, not an oversight: `docs/LUAX_DX_CURRENT_STATE.md` §8.1
  explains why — injecting any qualifying prefix (`d.`, an environment
  alias, anything) in front of a bare tag requires characters that don't
  exist in the original source at that position, which breaks the
  byte-length-preserving property the live virtual-source rewriter needs
  for `textDocument/rename`/`references` to work correctly (§8.4 of that
  document reproduces the alternative: a corrupted file). The
  `---@luax environment <alias>` pragma *does* work, but only in
  `compiler.compile`'s `virtual_luals` mode — the offline path used by
  `bin/luax check`'s lint and by real runtime compilation — not in the live
  interactive LSP path.
- **Lexical tags do not have this problem and already pass their equivalent
  of scenario A cleanly**: `<d.button />` (with `local d =
  require("hydronium.dom")`) gets full real completion (51 items at `<d.|`,
  verified in `LUAX_DX_CURRENT_STATE.md`), hover, and rename — all through
  ordinary LuaLS member resolution on the real `d` value, no environment
  machinery involved at all.

**Net assessment**: the *architecture's* answer to "does DOM activate via
import" is honestly "no, not for bare tags, by design" rather than "yes" as
the mission's matrix assumed — and the reason is a hard, already-discovered
correctness constraint (byte-alignment for rename), not an unaddressed gap.
Closing this gap the way the mission's matrix wants (bare tags becoming
valid specifically when DOM is imported) would require either reintroducing
global per-tag pollution (rejected — see below) or building a genuine
source-mapping layer instead of the current byte-identity virtual-source
trick, which is a real, separate piece of design work, not a bug fix.

## Scenario B, verified in full (real diagnostic + hover)

```lua
local h = require("hydronium")

return <button>Click</button>
```

Real `lua-language-server` response:
```
(global) button: unknown
Undefined global `button`.
```

This is the correct, honest outcome per Hard Release Gate #3 ("DOM types
are not globally active without the DOM environment") — a project that
never imports `hydronium.dom` gets no DOM completion leakage whatsoever for
bare tags, confirmed via a real diagnostic, not an absence-of-evidence
inference.

## Q13 / #13 — hidden global declarations defeating isolation?

**No**, verified two ways:

1. `.luarc.json`'s `diagnostics.globals` list no longer includes
   `__luax_intrinsic` (removed earlier this session, since it's no longer
   emitted anywhere live) — only `__luax`, `__luax_component`,
   `__luax_fragment` remain, and those back real, typed helpers in
   `types/luax.d.lua`, not a DOM catalog.
2. `d` (from `types/dom/init.d.lua`) *is* a real ambient global from
   LuaLS's point of view — but it is only ever *referenced* by code that
   already lexically wrote `d.something`, which itself only type-checks
   meaningfully if the file also did `local d = require("hydronium.dom")`
   (shadowing the ambient one with the real local of the same name — since
   Lua resolves `d` to the nearest lexical binding, a file that never wrote
   that `require` still has `d` resolve to the *ambient* global type if it
   happens to write bare `d.whatever`, which is a real, narrow residual
   leak: **a file that never imports `hydronium.dom` but happens to
   reference an identifier literally named `d`** would get DOM-shaped
   completion on it. This is a real, if narrow, edge case worth knowing
   about — it wasn't hit by any of this session's test files (none used a
   bare `d` without importing it), but it means the isolation guarantee
   technically depends on `d` not being reused as an unrelated local/global
   name elsewhere in a project that doesn't use Hydronium's DOM at all.

## Third-party host, zero plugin changes

Already proven earlier this session (not re-run here, see
`LUAX_DX_CURRENT_STATE.md`): an `---@luax environment t` pragma test using a
fixture host module (`local t = require("hydronium.terminal")`-shaped) with
its own `box`/`text` intrinsics correctly aliased bare tags to `t.box`/`t.text`
in real compiled output, and lexical `t.box`-style tags would get full LuaLS
member completion the same way `d.button` does — through ordinary Lua module
typing, no LUAX-plugin-side changes required for a new host. A hyphenated
custom-element-style bare tag (`<reactor-core />`, matching the mission's
Starship example literally) was attempted this session but hits the same
scenario-A/B limitation above (hyphenated names can't be expressed as a
lexical dotted path in Lua at all — `s.reactor-core` is not valid Lua
syntax, since `-` is the subtraction operator), so that exact bare-hyphenated
form is not currently typeable through either mechanism. A third-party host
that wants typed intrinsics today should expose non-hyphenated member names
(`s.reactorCore` or `s.ReactorCore`) rather than hyphenated bare tags.
