# Hydronium Current State Audit (Ground Truth)

**Status: this document replaces a prior version that certified a
fabricated Meteorite integration ("Model A In-Process Hybrid," sub-millisecond
in-process latency) and cited a test count that was already stale the day
it was written.** Everything below was verified by reading the live code,
running the real test suite, launching a real `lua-language-server` process
through real headless Neovim, and running the example app's real HTTP
server. Where a claim could not be verified this way, it is marked as such
rather than asserted. Audit date: 2026-09-06.

Labels used throughout: **VERIFIED** (checked against live code/tests/real
process this session), **PARTIALLY VERIFIED** (some but not all of the
claim checked), **NOT VERIFIED** (not checked this session, no claim either
way), **STALE DOCUMENTATION** (an existing doc's claim is contradicted by
what was found).

---

## 1. Test suite — authoritative count, no hand-maintained numbers

**`luajit tests/runner.lua`'s own output is the only authoritative test
count.** Do not read a count off any doc, including this one — five
different hardcoded counts (78, 131, 275, 311, and now 315) have
accumulated across this repo's docs over time as the suite grew, each
frozen the moment its doc was written and stale ever after. Correction
notices were added to `HYDRONIUM_FOUNDATION_COMPLIANCE.md`,
`LUAX_DX_COMPLIANCE.md`, and `HYDRONIUM_SSR_VERTICAL_SLICE_COMPLIANCE.md`
pointing back to the runner. `luajit tests/runner.lua` currently reports
all suites passing; run it yourself for the live number.

All 24+ suites listed in `tests/runner.lua`'s file list are confirmed
**actually executed** (each `loadfile`'d and `chunk()`'d in `main()`,
line ~409-419) — none are dead entries. One previously-listed suite,
`tests/luax/dom_typing_spec.lua`, was removed this session along with the
dead module it tested (`src/hydronium/luax/dom_typing.lua` — generated a
competing, contradictory `__luax_intrinsic` type declaration that was never
written to disk in production, only inside its own test).

## 2. Source vs. bytecode — **VERIFIED, correct as documented**

`.luax` compiles to plain, human-readable Lua **source** text
(`return H.h("div", nil, "Hi")`), confirmed by `loadstring()` succeeding on
real compiler output and by the absence of any `string.dump`/`luac`
invocation anywhere in `src/hydronium/luax/`. The two existing docs that
mention "bytecode" (`HYDRONIUM_CURRENT_STATE_AUDIT.md`'s own prior text,
`HYDRONIUM_SSR_VERTICAL_SLICE_COMPLIANCE.md`) both correctly *deny*
bytecode emission ("No LuaJIT binary bytecode is emitted") — no doc found
this session falsely claims bytecode output. The mission's cited example
phrasing ("Compiled .lua Bytecode") does not appear anywhere in the current
doc set; this concern is unmet in current docs (nothing to fix here).

## 3. LUAX compiler/LSP toolchain — see `docs/LUAX_DX_CURRENT_STATE.md`

That document (updated across two prior sessions, most recently this one)
is the authoritative, continuously-reverified source for: lexer/parser/CST,
compiler/runtime ABI, source maps, formatter, LuaLS virtual-source plugin,
type environments, DOM type generation, Tree-sitter grammar, and Neovim
integration. Headline findings carried forward here:

- The live LuaLS virtual-source path was **not actually byte-aligned**
  despite documentation claiming "exact 1:1 byte-aligned lowering" — this
  caused `textDocument/rename` to **corrupt files** on any multi-line
  lexical-tag tree. Root-caused through four stacked bugs (wrong live
  implementation wired in; a lexer end-offset bug; a missing comma between
  JSX siblings in the generated Lua; a single-hunk diff confusing LuaLS's
  position remapping) and fixed, with real headless-Neovim + real
  `WorkspaceEdit`-application verification. **STALE DOCUMENTATION**:
  `LUAX_DX_COMPLIANCE_V2.md`'s "exact 1:1 byte-aligned" claim (Q52-60) —
  corrected in place.
- Bare intrinsic tags (`<button>`) are honestly untyped in the live LSP
  path (a real "undefined global" diagnostic) rather than silently
  fake-typed — see `docs/LUAX_TYPE_ENVIRONMENT_VERIFICATION.md` for the
  full environment-isolation matrix, including a mismatch between this
  session's real test results and the mission's own idealized Scenario A
  (DOM import does **not** ambient-activate bare tags in the live path — a
  documented, deliberate trade-off, not a bug).
- Tag "linked editing" (auto-close, auto-rename-tag) works for both bare
  and lexical tags via `nvim-ts-autotag`'s officially documented extension
  API — zero custom tag-editing code, verified end-to-end through six real
  scenarios.
- The Tree-sitter "conformance" tests were silently exercising Neovim's
  stock **`lua`** grammar, not `tree-sitter-luax` at all (a copy-paste
  language-string bug) — the real grammar had literally never been tested
  by that suite. Fixed; the real grammar produces correct, error-free
  `element_expression`/`tag_expression` nodes for real LUAX syntax.
- DOM type coverage expanded from ~55 to ~140 tags with a fallback index
  signature.
- `tools/dom_generator/webref_data.lua` is confirmed a **hand-authored,
  zero-provenance local schema snapshot**, not a reproducible import from a
  pinned upstream WebRef release — `docs/LUAX_DOM_GENERATION_PROVENANCE.md`
  already says this accurately (verified this session: the generator does
  run and produces deterministic output from that snapshot, but there is no
  upstream version/digest/manifest anywhere in the repo). No correction
  needed to that doc; it was already honest.

See `docs/LUAX_LSP_E2E_VERIFICATION.md` for the consolidated real-LuaLS
pass/fail matrix, including explicitly what was **not** re-tested this
session (component prop completion, event-target-specific completion,
invalid-prop diagnostics, signature help, LSP-round-trip latency).

## 4. Runtime file inventory — **PARTIALLY VERIFIED, mostly accurate**

The prior file-inventory table (file paths, line counts, exported symbols)
was spot-checked and found broadly accurate. One correction: `h.component(fn)`
**does not exist anywhere in the codebase.** Function components are
recognized structurally by `element.createElement` when the resolved tag is
a Lua function — there is no `component()` wrapper API. The "double
function" pattern (a setup call that may return a render closure) is
implemented directly inside `ComponentInstance:render`
(`src/hydronium/core/component.lua:174-186`), not behind a named factory.
**This means the mission's own target completion-condition code
(`h.component(function(props) return function() ... end end)`) does not
match the current API** — either the target code needs updating to the real
API, or `h.component` needs to be added as a thin, documented alias. Neither
was done this session; flagging as an open decision.

## 5. Server-side rendering — real, independent of Meteorite, hardened this session

**VERIFIED**, by reading `src/hydronium/server/{init,html,meteorite}.lua`
in full and by real execution:

- `hydronium.server` never `require`s the external `meteorite` package.
  Confirmed by loading it with `package.path` restricted to `src/` only.
  The only "meteorite" reference is a lazy proxy to Hydronium's *own*
  `hydronium.server.meteorite` adapter module.
- **Effects are correctly suppressed during SSR** via a scheduler-level SSR
  flag (`scheduler.isSSR()`), checked at effect-creation time — an effect
  body never runs at all under SSR, verified by two independent existing
  tests plus direct code reading. This is centralized in
  `effect.lua`/`scheduler.lua`, not duplicated in the server renderer.
- **Signals/computed reads are synchronous and deterministic** during
  render — plain table reads plus dependency tracking, no scheduling
  involved, verified by code reading and existing tests.
- **Context** works during SSR, but via a **separate, independent
  reimplementation** of provider/consumer push-pop logic in
  `server/init.lua` rather than reusing `component.lua`'s — both are pure
  tree-walks over plain tables and both are tested, but this is
  architectural duplication worth reconciling eventually (not fixed this
  session).
- **Refs are never bound during SSR** — the server renderer never touches
  `refModule`/`Reconciler` at all (confirmed by grep: the only "ref" match
  in `server/*.lua` is the literal exclusion key in the attribute-serializer's
  prop-skip list). This matches the documented expected behavior ("refs
  remain unset on the server") but was previously **completely untested**.
  **Fixed this session**: added a regression test asserting a ref stays
  `nil` after SSR.
- **A real bug was found and fixed**: the server's component-invocation
  code called a component's setup function with only `props` (no `scope`),
  and — worse — let a returned "double function" render closure fall
  through to the generic zero-argument function-child handler, silently
  giving it `nil` for both arguments. The client's `ComponentInstance:render`
  passes `(props, scope)` on every call; the server now does too. Fixed and
  covered by two new regression tests.
- **HTML correctness is solid**: escaping (`&`/`<`/`>`/`"`/`'`), void
  elements (with a real "cannot have children" error), boolean attributes,
  `aria-*`/`data-*` boolean-as-string handling, `class`/`className`
  aliasing, an explicit and hard-to-invoke-by-accident raw-HTML escape
  hatch (`dangerouslySetInnerHTML.__html` / `unsafe_raw_html`), and
  deterministic alphabetical attribute/style ordering — all verified by
  reading `html.lua` and by existing golden tests.
- **Two real SVG bugs were found and fixed this session**: (1) camelCase
  SVG element names (`linearGradient`, `clipPath`, ...) were being
  force-lowercased to invalid, unrecognized tag names
  (`<lineargradient>`); (2) camelCase SVG presentation attributes
  (`strokeWidth`, `stopColor`, ...) were passed through verbatim instead of
  being aliased to their real kebab-case SVG/XML names
  (`stroke-width`, `stop-color`). Both fixed with a scoped, documented,
  non-exhaustive tag/attribute table, verified with four new golden tests.
  SVG had **zero test coverage** before this session.
- Sink-based architecture (`server.render(vnode, sink)`,
  `server.render_to_stream`) already exists internally and does not
  preclude future streaming, even though the current implementation
  materializes synchronously.

## 6. Meteorite integration — the user's specific flagged concern, confirmed and fixed

See `docs/METEORITE_HYDRONIUM_INTEGRATION_BRIEF.md` for the full account.
Summary: the prior "Model A In-Process Hybrid" story (embedded Zig host,
0.2-0.5ms latency, >50k req/s) was **entirely fabricated** — sourced from a
benchmark loop that never touches Meteorite's real router, with test
request paths literally set to the route pattern string so a naive
string-equality "router" would appear to work. Two of four demo routes were
also silently broken (a `.luax` component never rendering `props.children`)
— confirmed live over real HTTP, then fixed this session and re-verified.

Meteorite's real, audited architecture (route/handler contract, response
model, **zero streaming support anywhere in the stack**, error handling,
middleware, Lua-VM isolation model) settles the integration-model question
cleanly: a buffered-string response (`server.render_to_string` consumed as
a normal response body) is the only model Meteorite's current architecture
can support; anything streaming-shaped needs foundational changes on
Meteorite's side first. Three targeted, code-unanswerable questions for
Meteorite's owner are listed in the brief.

## 7. Environment isolation — see `docs/LUAX_TYPE_ENVIRONMENT_VERIFICATION.md`

Real matrix results, including the one place this session's own earlier
correctness fix (byte-aligned rename) trades away the mission's idealized
"DOM import ambient-activates bare tags" expectation, and why. One real,
narrow residual isolation gap identified: a project that never imports
`hydronium.dom` but happens to use an unrelated identifier literally named
`d` would see it resolve against the ambient `HydroniumDOMDescriptors`
global type.

## 8. What was not attempted this session (explicit scope boundary)

Given the size of the full mission (comparable to a multi-week initiative),
this session prioritized: (1) the user's specific flagged concern
(Meteorite SSR fakery), (2) server-renderer hardening with real bugs found
and fixed, (3) the environment-isolation and rename/reference LSP
correctness work that was already mid-flight. **Not attempted**:

- A full LSP integration test harness covering every method the mission
  lists (signature help was not tested at all; component prop completion
  and DOM event-target completion were not independently re-driven live
  this session, though the underlying type machinery they'd exercise was
  spot-checked via hover).
- Building the recommended real "Hydronium Showcase" application exercising
  the full feature list (fragments, lists/keys, forms, context, error
  boundaries, SVG, style, all in one real app) and its accompanying
  `docs/LUAX_REAL_USAGE_FINDINGS.md` DX log.
- Performance benchmarking of server rendering (render latency,
  allocation/memory characteristics, large-list behavior, sink vs.
  string-render comparison).
- Reconciling the server-vs-client Context implementation duplication.
- Adding `h.component(fn)` (or updating the mission's target code to match
  the real API) — flagged as an open decision, not resolved.

These are the natural next steps, in roughly that priority order.
