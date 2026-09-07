# LUAX LSP End-to-End Verification (Ground Truth)

All results below were produced by launching a real `lua-language-server`
process (via Mason, the same binary a real Neovim/VS Code user would run)
through real headless Neovim, sending real LSP requests, and reading real
responses — never by inspecting compiler/transformer output as a proxy.
Full narrative and root-cause detail (including two serious bugs found and
fixed) lives in `docs/LUAX_DX_CURRENT_STATE.md` §4 and §8; this document is
the consolidated pass/fail matrix the mission's final questions ask for.

Audit date: 2026-09-06. LuaLS version: whatever Mason had installed in this
environment (not pinned/recorded by version string in this pass — see open
item below).

## Matrix

| Capability | Target | Result | Evidence |
|---|---|---|---|
| `lua-language-server` actually launched | any | ✅ real process, via Mason | `LUAX_DX_CURRENT_STATE.md` throughout |
| `.luax` opens through LSP | any | ✅ | `filetype=luax`, client attaches |
| Ordinary Lua hover inside `.luax` expr | `user.profile.name` | ✅ correct structural type inferred (`local user: { profile: table }`) | this session, real hover response |
| Ordinary Lua definition inside `.luax` expr | `user` → its `local` | ✅ jumps to the correct line/column | this session, real definition response |
| Lexical tag completion | `<d.\|` | ✅ 51 real items (`button`, `div`, `h1`-`h4`, ...) via plain LuaLS member completion, no custom provider | `LUAX_DX_CURRENT_STATE.md` |
| Lexical tag hover | `<d.mark>`, `<d.button>` | ✅ correct `hydronium.Intrinsic<P,H>` type shown | `LUAX_DX_CURRENT_STATE.md` |
| Lexical tag rename (opening tags) | rename `d` → `dom2` | ✅ all 3 opening-tag occurrences correctly updated | `LUAX_DX_CURRENT_STATE.md` §8.4 |
| Lexical tag rename (closing tags) | same | ❌ closing tags not updated (text is blanked in the virtual doc, no identifier there to rename) — a distinct, documented gap, not corruption | `LUAX_DX_CURRENT_STATE.md` §8.4, §9 |
| Tag-name-edit linked sync (open↔close) | edit `<div>`→`<span>` directly | ✅ via tree-sitter `nvim-ts-autotag` integration (not LSP rename) — works for bare **and** lexical/dotted tags | prior session, `LUAX_DX_CURRENT_STATE.md` §9 |
| Bare tag typing (no environment) | `<button>` | Honestly untyped (`undefined global`) | this session, `LUAX_TYPE_ENVIRONMENT_VERIFICATION.md` |
| Bare tag typing (DOM imported) | `<button>` | Still honestly untyped — **does not match the mission's Scenario A**, deliberate trade-off, see `LUAX_TYPE_ENVIRONMENT_VERIFICATION.md` | this session |
| DOM-not-imported isolation | `<button>` with no `require("hydronium.dom")` | ✅ no DOM leakage (same "undefined global" outcome as above) | this session |
| Diagnostics point to original `.luax` coordinates | undefined-global on a bare tag | ✅ correct line/col in the *original* file, not virtual-doc-shifted | this session (diagnostic range matched source position) |
| Component prop completion | typed `---@class ButtonProps` + `<Button \|` | **Not independently re-tested this session** — not run against a real component fixture; existing unit tests (`tests/luax/*`) assert virtual-source shape only | open item below |
| Literal prop value completion | `<Button variant="\|" />` | **Not tested** | open item below |
| DOM event target typing | `<button onClick={function(event) event.currentTarget.\| }}>` | **Not independently re-tested this session** (verified conceptually via `d.button`'s `hydronium.Intrinsic<HTMLButtonProps, HTMLButtonElement>` hover type, but the specific `event.currentTarget.` completion-inside-callback scenario was not driven through a live completion request this session) | open item below |
| Invalid DOM usage diagnostics | `<button definitelyNotAProp={123} />` | **Not tested** | open item below |
| Signature help | any | **Not tested** | open item below |
| p50/p95 completion latency | separated from virtual-transform cost | **Not measured** — `benchmarks/luax/*` measure transform latency only, as the mission itself flags; no LSP-round-trip latency harness was built this session | open item below |

## What this session actually added beyond the prior pass

- Confirmed real diagnostics (not just completion/hover) point to correct
  original-file coordinates for a concrete case (undefined-global on a bare
  tag).
- Confirmed ordinary-Lua intelligence (hover + go-to-definition) survives
  correctly inside a `.luax` embedded expression referencing a plain local
  variable with an inferred structural type — this was previously untested.
- Ran the environment isolation matrix for real (A/B/D; C not independently
  re-run, see `LUAX_TYPE_ENVIRONMENT_VERIFICATION.md`) and found the
  mission's Scenario A does not hold, with a full explanation of why (a
  deliberate trade-off, not an unknown bug).

## Explicitly open (not completed this session)

Given the size of the full mission, these real-LSP checks were not run this
session and should not be assumed to pass:

1. **Typed component prop completion** (`<Button |` → `variant`/`disabled`/`onPress`)
   against a real `---@class`-annotated component fixture.
2. **Literal union-value completion** (`<Button variant="|"`).
3. **Event-target-specific completion inside a callback body**
   (`event.currentTarget.|` resolving to `HTMLButtonElement` vs.
   `HTMLInputElement` members) — driven live, not inferred from a hover on
   the outer type.
4. **Invalid-prop diagnostics** (`definitelyNotAProp={123}`) — does LuaLS
   actually flag an unknown field on a strict-shaped props type, or does
   the mixed-table `{[integer]: any}` support (added for children) make
   props types too permissive to catch this?
5. **Signature help.**
6. **A proper completion/hover/diagnostics *latency* harness**, separated
   from virtual-transform cost, with p50/p95/max — `benchmarks/luax/`
   currently only measures the Lua-side transform, not an LSP round trip.
7. **The exact LuaLS version** was not pinned/recorded — a real
   reproducibility gap for anyone trying to reproduce these results later.

These represent the realistic remaining scope of Part II of the mission —
they were deprioritized in favor of the Meteorite-integration audit (the
user's specific, higher-priority concern this session) and the server
renderer hardening, both completed. Recommended as the next session's
starting point if LSP DX verification continues.
