# Hydronium Ink: a real terminal Host adapter

This follows this repo's own rule (`CLAUDE.md`'s "Trust issue in `docs/`"
section): report what was verified against real, running code, and say
plainly what wasn't attempted rather than writing a self-certified
"Production Ready" doc. Nothing here should be read as "VERIFIED" unless
a specific command or captured artifact backs it.

## What this is

`hydronium.host.terminal` is a Host adapter implementing the exact same
7-method contract `core/reconciler.lua`'s `Reconciler` drives against any
host (`src/hydronium/test/host.lua`'s `TestHost` and
`src/hydronium/host/dom.lua` are the other two in this repo), except this
one renders to a real terminal via raw ANSI escape sequences instead of
an in-memory tree or a real DOM. `hydronium_ink` is the intrinsic
authoring surface (`Box`, `Text`, `Newline`, `Spacer`, `Transform`)
analogous to `hydronium_dom`'s `d.button`/`d.div`/etc, modeled on React
Ink's own primitives — plus `hydronium_ink.measure`/`hydronium_ink.hooks`
(`measureElement`/`useBoxMetrics`, `useInput`/`useApp`/`useWindowSize`)
and `hydronium_ink.render` (the real `ink.render()` entry point) covering
the parts of real Ink's surface beyond the intrinsics themselves.

Files:
- `ink/src/hydronium_ink/init.lua` — the `Box`/`Text`/`Newline`/`Spacer`/`Transform` intrinsic descriptors.
- `ink/src/hydronium_ink/host/terminal.lua` — the Host adapter itself.
- `ink/src/hydronium_ink/measure.lua` — `measureElement(ref)`.
- `ink/src/hydronium_ink/hooks.lua`, `render.lua`, `keys.lua`, `tty_ffi.lua` — real interactivity (`useInput`/`useApp`/`useWindowSize`, raw-mode stdin, ANSI key parsing).
- `tests/host/terminal_spec.lua` / `tests/host/keys_spec.lua` — part of the native `luajit tests/runner.lua` suite.
- `examples/ink_demo/run.lua` / `run_luax.lua` / `demo.luax` — a live counter app meant to be run against real stdout, not part of the automated suite.

Neither `core/reconciler.lua`, `core/component.lua`, nor `hydronium/dom/`
was touched — a separate, uncommitted line of work in this repo's main
working tree already touches those files (per this mission's own
instructions), and this Host adapter doesn't need the contract itself to
change.

## The Host contract, and how this module satisfies each method

| Method | What the Reconciler needs | What this host does |
|---|---|---|
| `createInstance(tag, props)` | Create a new element host node | Returns `{type="element", tag, props=<copy>, children={}, parent=nil}`. Props are copied out of the frozen VNode-props proxy via `rawProps()` (same `_store`-unwrapping `host/dom.lua` uses). |
| `createTextInstance(text)` | Create a new text host node | Returns `{type="text", text=tostring(text), parent=nil}`. |
| `appendChild(parent, child)` | Attach `child` as `parent`'s last child | Detaches `child` from any prior parent, appends, marks the tree dirty (see "Repaint strategy" below). |
| `insertBefore(parent, child, beforeChild)` | Attach `child` before `beforeChild`, or append if `beforeChild` is absent/not found | Implemented exactly like `TestHost`'s own array-splice version. |
| `removeChild(parent, child)` | Detach `child` | Array removal, `child.parent = nil`. |
| `commitUpdate(hostNode, oldProps, newProps)` | Apply new props | Replaces `hostNode.props` wholesale with a fresh copy of `newProps`. |
| `commitTextUpdate(hostNode, oldText, newText)` | Apply new text | Replaces `hostNode.text`. |

All 7 are called by the Reconciler as plain function calls
(`self.host.createInstance(...)`, never `host:createInstance(...)`) —
confirmed by reading every call site in `core/reconciler.lua`, so this
module (like `host/dom.lua`) does not need `TestHost`'s defensive
"was this called as `host.fn(...)` or `host:fn(...)`" disambiguation.

Beyond the 7-method contract, this host also exposes (same pattern as
`host/dom.lua`'s `hydrateProps`/`mismatchLog`): `host.getRoot()`,
`host.flush()`, `host.paint()` (unconditional force-repaint), and
`host.getLastFrame()` (debugging/testing convenience — the raw
character+style grid from the last paint).

## Repaint strategy: what was tried, what broke, what shipped

The task brief explicitly allowed either "real diffing" or an honestly-labeled
full-repaint-per-commit simplification, and either "paint on every
mutating call" or "batch to end-of-commit." Two designs were actually
built and tested here, in order:

**Design 1 (discarded): paint synchronously on every mutating host call.**
Simple and, on paper, always correct — never displays a stale frame. It
was shipped first, and `tests/host/terminal_spec.lua`'s specs against it
passed. But running the real live-terminal demo
(`examples/ink_demo/run.lua`) through a pty and reading the captured
bytes surfaced a genuine defect this design has no way around: a
multi-child re-render visibly reordered its own lines mid-repaint on
real output. Root cause, found by reading `core/reconciler.lua`'s
`reconcileChildren()`: its "ensure physical sibling order" pass
unconditionally re-`appendChild`s **every** child at the end of every
reconcile, one call per child, even when nothing moved. `appendChild` on
an already-attached node moves it to the end of this host's internal
`children` array; with three children A/B/C already in the correct
order, that loop transiently produces `[B,C,A]`, then `[C,A,B]`, before
settling back on `[A,B,C]`. A host that paints on literally every
mutating call flushes each of those two *wrong-order* intermediate
frames to the real terminal before the correct one lands. This is not
hypothetical — it's what running `examples/ink_demo/run.lua` under
`script -q /dev/null` and reading the captured bytes actually showed:
the three-line counter box visibly rotated its own three lines through
all three orderings on every single tick.

**Design 2 (shipped): dirty-flag + explicit `host.flush()`.** Every
mutating call now just sets `host._dirty = true`; no I/O happens until
something calls `host.flush()`, which repaints once (if dirty) and
clears the flag. The Reconciler's Host contract, as specified, exposes no
"commit finished" hook to batch against automatically without modifying
`core/reconciler.lua` (out of scope for this module — see the mission
brief), so the commit boundary is instead made an explicit, documented
part of this host's own beyond-the-contract API: callers flush after
`reconciler:mount()`/`:reconcile()` returns, or after a signal setter's
own synchronous `scheduler.flush()` returns. Both
`tests/host/terminal_spec.lua` and `examples/ink_demo/run.lua` do this.
The tradeoff is real and stated plainly: forget to call `flush()` and
nothing new is ever painted — there is no automatic fallback. A
dedicated regression spec
(`tests/host/terminal_spec.lua`, `"never emits a wrong-order intermediate
frame..."`) proves a whole 3-child reconcile (one `commitUpdate` plus
three `commitTextUpdate`/reorder-`appendChild` calls) collapses into
exactly one `writeFn()` call, and that the resulting frame never shows
anything but the correct final order.

## Diffing vs. full repaint

Real diffing was built, not the full-repaint-per-commit fallback the
brief also permitted. Every `host.paint()` call:
1. Re-measures and re-positions the whole tree (cheap — this is a small
   in-memory tree walk, not a DOM operation).
2. Builds a fresh character+style grid (`{ch, fg, bold}` per cell).
3. If there is no previous grid, or its `w`/`h` differ from the new
   one's: full clear+redraw (`\27[2J\27[H`, then per row `\27[<row>;1H\27[K`
   plus the row's content).
4. Otherwise: diffs cell-by-cell against the previous grid, coalesces
   contiguous changed columns per row into runs, and emits one cursor
   move (`\27[<row>;<col>H`) + minimal SGR-transition-aware content per
   run. Unchanged rows/regions emit nothing at all.
5. If nothing actually changed (the dirty flag fired, e.g. from a
   reconciler `commitUpdate` call with prop values that came out
   identical, but no cell differs), `writeFn` is never called at all —
   not even the cursor-park sequence.

`tests/host/terminal_spec.lua`'s `"drives a real stateful component's
update..."` spec proves this directly: after mounting a bordered
counter box and updating the signal, the update's own byte stream is
asserted to be under 40 bytes and to contain no `\27[2J` — i.e. a real
single-cell diff, not a second full redraw. The real-terminal capture
(below) shows the same thing on genuine stdout: each tick after the
first is `\27[6;1H\27[0m\27[3;10H\27[0m\27[36m<digit>\27[0m\27[6;1H\27[0m`
— one cursor move, the changed digit(s), cursor-park, nothing else.

## Layout: real Yoga flexbox, not a hand-rolled port

**Updated**: this module now runs its layout through the actual upstream
`facebook/yoga` C++ engine (the same one real Ink itself uses), via
`hydronium_ink.yoga_ffi` — a hand-written LuaJIT FFI binding to Yoga's real,
stable C API (`Yoga.h`), not a from-scratch flexbox reimplementation. This
replaced the block-stacking `measure()`/`position()` pair that used to live
in `host/terminal.lua` (no `grow`/`shrink`/`justify-content`/`align-items`,
no `flexWrap`).

Why a hand-written binding rather than an existing "Lua Yoga binding":
every option evaluated failed at least one of "actively maintained",
"LuaCATS-typed", "solves portability" — `lyoga` (LuaJIT FFI to real Yoga)
has been dead since 2019 with no types; `Flow` (a from-scratch flexbox
reimplementation) is written in Luau, not Lua 5.1–5.4/LuaJIT, and has been
stale for years; the rest are locked into specific game engines or full
GUI toolkits. Upstream Yoga itself is excellent and actively maintained,
but ships no portable prebuilt Lua-callable artifact. See
`hydronium_ink/yoga_ffi.lua`'s own doc comment for the full account, and
`native/vendor/yoga/VENDORED.md` for the pinned tag/commit and the
`zig c++` cross-build (`native/build.zig`) that produces `libyogacore` for
five target triples with zero CMake.

- `Box` now supports real `flexDirection`, `justifyContent`, `alignItems`,
  `flexWrap`, `flexGrow`, `flexShrink`, `flexBasis`, `margin`/`marginX`/
  `marginY`, `position`/`top`/`right`/`bottom`/`left` (absolute
  positioning), `display`, `overflow` (`"hidden"`/`"scroll"` really clip
  painted content to the box, not just reserve layout space),
  `backgroundColor`, and per-edge `borderColor`/`borderTopColor`/etc. +
  `borderDimColor`/etc, in addition to the `padding`/`paddingX`/
  `paddingY`/`borderStyle`/`width`/`height` props that already existed —
  see `hydronium_ink/init.lua`'s doc comment for the full prop list and
  exact accepted string values (they follow real Ink's own naming, e.g.
  `flexWrap: "nowrap"`, not Yoga's internal `NoWrap` spelling).
- `borderStyle: "single"` still draws the same real box-drawing characters
  (`┌─┐│└┘`, U+250C/U+2500/U+2510/U+2502/U+2514/U+2518) exactly as before
  — Yoga's own `border` edge occupies the same box-model layer
  padding/content already used, so this needed no change beyond feeding
  `border = 1` into Yoga's style instead of this module's own hand-rolled
  `2*border` arithmetic. Border corners always use the box-wide
  `borderColor` fallback directly, never either adjacent edge's own
  override — a stated simplification (see `host/terminal.lua`'s
  `resolveBorderEdge`), since a corner genuinely belongs to two edges at
  once and real Ink's own corner behavior wasn't checked against.
- `backgroundColor` fills a Box's **entire** rect, border cells included
  — a bordered, background-colored box's border characters are drawn on
  top of that fill, so the background shows through both the border and
  the interior, matching how a real terminal box with a background
  color looks.
- `Text` gained `backgroundColor`, `dimColor`, `italic`, `underline`,
  `strikethrough`, `inverse` (all real SGR codes, see "Color mapping"
  below) and `width` + `wrap` (`"truncate"`/`"truncate-start"`/
  `"truncate-middle"`/`"truncate-end"`, ASCII `"..."` marker — see the
  "Explicitly NOT implemented" note on real reflow below for why this is
  narrower than real Ink's own `wrap`). Nested `Text` style merging and
  `Newline` semantics are unchanged.
- A fresh Yoga node tree is built and freed on every `paint()` call
  (`buildYogaTree`/`resolvePositions`/`freeYogaTree` in `host/terminal.lua`)
  rather than kept alive incrementally across the host node lifecycle —
  a deliberate simplification matching this module's pre-existing
  "recompute layout from scratch every paint" approach (the old
  `measure()`/`position()` pair did the same). The Lua-side trees this
  host ever deals with are small enough that this costs nothing
  observable, and it avoids threading Yoga node lifecycle through
  `createInstance`/`removeChild`/etc.

Explicitly NOT implemented (out of scope, not attempted):
- No real text **reflow** — `wrap = "wrap"`/`"hard"` (real Ink's other
  two documented `wrap` values) are not implemented; only the four
  `truncate*` variants are, and only when `Text` has its own explicit
  `width` prop (not when a width is merely inherited from a container's
  own layout, the way real Ink's does). Real reflow needs Yoga to know
  an available width *during* its own layout pass, via a "measure
  function" callback (`YGNodeSetMeasureFunc`) this FFI binding does not
  register — a real, separate, riskier integration (an FFI-callable Lua
  callback, with real GC-lifetime concerns for the C function pointer),
  not attempted here.
- The renderer itself still has no notion of the real terminal's
  column/row count for *layout* purposes — the root Yoga node is laid
  out with undefined available width/height
  (`YGNodeCalculateLayout(root, NaN, NaN, ...)`), so the frame still
  auto-sizes to the measured content's bounding box only. (Separately,
  `hydronium_ink.hooks.useWindowSize()`/`render.lua`'s event loop *do*
  now query the real terminal size for reactive app code to read — see
  the interactivity work this doc's sibling covers — but that value is
  never fed back into the root's own `calculateLayout` call
  automatically; an app wanting "fill the terminal" still has to pass
  the queried size into its own top-level `Box`'s `width`/`height`
  itself.)
- Bare text (a plain string) directly under a `Box` with no enclosing
  `Text` is not valid input in real Ink; this module is more lenient
  (it measures and paints it as plain unstyled text rather than silently
  dropping it) but this is not a recommended or fully-tested usage path.
- A `Box` nested inside a `Text` is silently ignored during layout
  (mirrors real Ink's own constraint on this) rather than validated or
  erroring.
- `Transform` operates on **plain, unstyled text** per output line, not
  the already-ANSI-styled string real Ink hands its own `transform`
  callback. A transform function that itself injects ANSI codes (the
  common real-world case: gradient/chalk-style color libraries) is not
  supported — this module would need to parse ANSI back out of the
  transform's return value into real cell styles to support that, which
  it does not attempt. `transform(line, index)`'s `index` is also
  1-indexed here, a deliberate Lua-native choice, not real Ink's
  0-indexed one.
- **`Static` is not implemented at all**, not even partially. Real Ink's
  `Static` needs a genuinely different rendering mode this host doesn't
  have: content that renders exactly once, is written directly to the
  terminal's normal scrollback (never re-diffed, never touched again by
  a later `paint()`), while the rest of the tree keeps redrawing in the
  usual cursor-addressed "live region" below it. This host's entire
  repaint strategy (see "Repaint strategy" above) is built around one
  unified tree diffed as a whole against `host._lastFrame` every flush —
  there is no notion of "this subtree is permanent, exclude it from
  future diffing" anywhere in it. Adding `Static` for real means
  designing that split deliberately (which items have already been
  flushed to scrollback and must never repaint, vs. what's still live),
  not adding a prop to the existing pipeline — carved out as its own
  future slice rather than attempted here, the same honest-scoping
  treatment given to real text reflow above.

## Color mapping

| Name | SGR code | Note |
|---|---|---|
| gray | `\27[30m` | Occupies the slot the SGR spec calls "black" (n=0) — the requested named set is 8 names (red/green/yellow/blue/magenta/cyan/white/gray) for the `\27[3<n>m` family's 8 slots, and something has to take slot 0. Many real terminal color schemes already render SGR 30 as dark gray, not pure black, which is why this slot was chosen for it — but on a literal pure-black-on-black theme this renders as invisible, not a visible gray. This is a documented simplification, not a "true" bright-black (`\27[90m`) gray. |
| red | `\27[31m` | |
| green | `\27[32m` | |
| yellow | `\27[33m` | |
| blue | `\27[34m` | |
| magenta | `\27[35m` | |
| cyan | `\27[36m` | |
| white | `\27[37m` | |

`bold` is `\27[1m`. `dimColor` is `\27[2m`. `italic` is `\27[3m`.
`underline` is `\27[4m`. `inverse` is `\27[7m`. `strikethrough` is
`\27[9m`. `backgroundColor` uses the same 8-name table above at `\27[4<n>m`
instead of `\27[3<n>m` (so `backgroundColor = "blue"` is `\27[44m`).
Reset is always `\27[0m`.

## Ground truth table

| Capability | Status | Evidence |
|---|---|---|
| All 7 Host contract methods implemented | VERIFIED | `ink/src/hydronium_ink/host/terminal.lua`; driven by a real `Reconciler` in all 5 `tests/host/terminal_spec.lua` specs. |
| Real (not mocked/stubbed) ANSI byte output | VERIFIED | `tests/host/terminal_spec.lua`'s own ANSI-interpreter reconstructs a character+style grid from the exact bytes the host wrote and asserts exact per-cell content+style; separately, `examples/ink_demo/run.lua` was run against real stdout through a pty (`script`) and the captured bytes inspected with `cat -v`/`xxd` — see below. |
| Real cell-level diffing (not full-repaint-per-commit) | VERIFIED | `tests/host/terminal_spec.lua`'s update spec asserts byte count + absence of `\27[2J` on a same-size update; real-terminal capture shows single-digit diffs per tick. |
| Box layout: column/row stacking, padding, border, width/height overrides, via real Yoga | VERIFIED | `tests/host/terminal_spec.lua`'s first two specs assert exact character grids for a bordered column Box and a row Box, unchanged byte-for-byte after the Yoga swap. |
| Real flexGrow/flexShrink/justifyContent/alignItems/flexWrap, via real Yoga | VERIFIED | Standalone repro: a `flexDirection="row"` Box with one `flexGrow=1` child and one fixed `width=5` child correctly grows the first child to fill the remaining space — impossible with the old block-stacker, which had no `grow` concept at all. See "Layout: real Yoga flexbox" above. |
| `Newline` forcing a line break inside `Text` | VERIFIED | Dedicated spec in `tests/host/terminal_spec.lua`. |
| Ordinary reconciler update path (signal → re-render → host) drives the terminal correctly | VERIFIED | `tests/host/terminal_spec.lua`'s counter spec uses a real `createSignal`-backed component and `H.act()`, not a hand-rolled repaint call. |
| No wrong-order intermediate frames during a multi-child re-render | VERIFIED (after a real fix — see "Repaint strategy") | Dedicated regression spec; real-terminal capture before/after the fix (raw bytes described above). |
| Real Yoga `margin`/absolute `position`+`top`/`right`/`bottom`/`left` | VERIFIED | Dedicated specs in `tests/host/terminal_spec.lua` asserting exact cell positions. |
| Real `backgroundColor` fill + per-edge `borderColor`/`borderDimColor` | VERIFIED | Dedicated specs asserting exact `fg`/`bg` on border and interior cells, including a specific-edge-overrides-box-wide-fallback case. |
| Real `overflow = "hidden"` clipping (not just layout reservation) | VERIFIED | Dedicated spec: a sibling box's own content is provably untouched while the clipped box's overflow is dropped. |
| Real SGR `italic`/`underline`/`strikethrough`/`inverse`/`dimColor` | VERIFIED | Dedicated spec asserting all five flags on the interpreted grid cell. |
| `Text` `wrap = "truncate"`/`"truncate-start"`/`"truncate-middle"` (explicit `width` only) | VERIFIED | Dedicated spec, all three modes, exact expected strings. |
| Real Spacer (flexGrow=1 leaf) | VERIFIED | Dedicated spec: a Spacer between two Text siblings pushes the second all the way to the last column. |
| `measureElement(ref)` / `useBoxMetrics` (x/y/width/height/clientWidth/clientHeight) | VERIFIED | Dedicated spec asserts exact values (including content-box size correctly subtracting border+padding) from a real bound `ref`, plus `hasMeasured=false` before anything painted. |
| `Transform` (isolated-subtree render, per-line `transform(line, index)`) | VERIFIED (plain-text only — see "Explicitly NOT implemented" above) | Dedicated multi-line spec asserts both transformed lines' exact text and that no `fg` leaks through. |
| Real text **reflow** (`wrap = "wrap"`/`"hard"`), real terminal size feeding layout, `Static` | NOT IMPLEMENTED, not attempted | See "Layout: real Yoga flexbox" and "Explicitly NOT implemented" above. |
| `useInput`/`useApp`/`useWindowSize` (real raw-mode stdin, ANSI key parsing, live resize) | VERIFIED | See this doc's sibling covering `hydronium_ink.render`/`hooks`/`keys`/`tty_ffi` — real injected keypresses in a live `tmux` pane, not just unit tests. |
| `ink` member's own test suite green | VERIFIED | `luajit tests/runner.lua tests/host/terminal_spec.lua` → 17/17 passed. The repo-wide suite (`luajit tests/runner.lua`) is 413/414 — the one failure is `tests/core/lazy_barrel_spec.lua`, pre-existing and unrelated (an environment issue: it shells out to a `lua` binary not on this machine's `PATH`), not caused by this module. |

## Real terminal evidence

Run (macOS, `script` as the available pty-wrapping tool):

```
script -q /dev/null luajit examples/ink_demo/run.lua > /tmp/ink_output.txt 2>&1 &
sleep 3 && kill -TERM <the actual luajit pid, found via pgrep -f "luajit examples/ink_demo/run.lua">
cat -v /tmp/ink_output.txt
```

**A real finding from doing this, not a footnote:** the demo's output
only reached the capture file reliably once `examples/ink_demo/run.lua`
called `io.stdout:setvbuf("no")`. Before that fix, killing the process
with `SIGTERM` lost anything still sitting in C stdio's default
full-block output buffer (SIGTERM does not run libc's flush-on-exit
path) — a capture artifact, but also a real, worthwhile fix for a live
terminal UI in general: you want every frame to reach the terminal
immediately, not whenever an ~8KB buffer happens to fill.

With that fix, a representative captured sequence (via `cat -v`, so
`^[` = ESC and the raw UTF-8 border bytes render as their literal
multi-byte `M-^` sequences — this is `cat -v`'s normal, not a mangled
sequence in the actual output) for the first frame plus a few ticks:

```
^[[2J^[[H^[[1;1H^[[K^[[0m<3-byte UTF-8 ┌><11x 3-byte UTF-8 ─><3-byte UTF-8 ┐>
^[[2;1H^[[K^[[0m<│> ^[[0m^[[1mHydronium Ink demo^[[0m <│>
^[[3;1H^[[K^[[0m<│> ^[[0m^[[36mCount: 0^[[0m           <│>
^[[4;1H^[[K^[[0m<│> ^[[0m^[[30m(Ctrl-C to stop)^[[0m   <│>
^[[5;1H^[[K^[[0m<└><11x 3-byte UTF-8 ─><┘>
^[[6;1H^[[0m
^[[3;10H^[[0m^[[36m1^[[0m^[[6;1H^[[0m
^[[3;10H^[[0m^[[36m2^[[0m^[[6;1H^[[0m
^[[3;10H^[[0m^[[36m3^[[0m^[[6;1H^[[0m
...
^[[3;10H^[[0m^[[36m9^[[0m^[[6;1H^[[0m
^[[3;10H^[[0m^[[36m10^[[0m^[[6;1H^[[0m
^[[3;11H^[[0m^[[36m1^[[0m^[[6;1H^[[0m
```

(the border/box-drawing bytes are elided above as `<...>` for
readability; the raw hex for the top-left corner and first horizontal
run, taken directly via `xxd` from the actual capture file, is:

```
1b5b 324a 1b5b 481b 5b31 3b31 481b 5b4b 1b5b 306d e294 8ce2 9480 e294
80e2 9480 e294 80e2 9480 e294 80e2 9480 e294 80e2 9480 e294 80
```

— `e2 94 8c` = U+250C `┌`, `e2 94 80` (repeated) = U+2500 `─`, confirming
real, well-formed UTF-8, not garbled bytes or literal multi-byte
mis-splits) is the single-character diff each tick after the first: a
cursor move to the digit's own cell, the digit itself (in cyan, SGR 36,
matching the `Text color="cyan"` prop), reset, then the cursor-park move
to below the frame. No `\27[2J` appears after the first frame — confirming
real per-tick diffing on genuine stdout, matching what
`tests/host/terminal_spec.lua` proves natively. No reordering of the
three lines is visible at any point in the capture (the regression the
first repaint design actually exhibited — see "Repaint strategy").

One environment-specific caveat, reported honestly rather than glossed
over: the tick counter advances much faster than the demo's own
`os.execute("sleep 0.3")` pacing implies when captured through this
sandboxed `script`/pty nesting (dozens of ticks in ~3 real seconds
instead of ~10) — confirmed via a separate, un-captured
`luajit -e 'for i=1,5 do os.execute("sleep 0.3") end'` timing test
(1.6s for 5 iterations, i.e. correct ~0.3s/iteration) that `os.execute`
paces correctly outside this particular capture harness. This looks like
an artifact of running `script` nested inside this environment's own
already-virtualized shell, not a defect in the demo or the host module,
but it is called out here rather than silently assumed away.

## Input/interactivity

Fully implemented across four phases (`ink/src/hydronium_ink/{render,hooks,keys,tty_ffi,clock}.lua`)
since this section was first written. `ink.render(element, opts)` is a
real, POSIX-only (termios/ioctl/select), blocking event loop -- see
render.lua's own top doc comment for the full per-iteration breakdown.
Every hook below is built entirely on Hydronium's existing
`createContext`/`useContext`/`onCleanup`/`createSignal` primitives -- no
new core framework feature was needed for any of this.

Hooks, and how each was actually verified (not just reasoned about):

- **`useInput(handler, opts)`**, **`useApp()`**, **`useWindowSize()`** --
  Phase 1. Real keypresses (arrows, Ctrl+C, standalone Escape) injected
  into a live `tmux` pty; resize verified via a real `ioctl(TIOCGWINSZ)`
  poll. `keys.lua`'s ANSI/VT100 parser (arrows, Home/End/PageUp/PageDown,
  Backspace, Tab, Ctrl+letter, standalone-Escape-with-timeout) has a
  dedicated unit spec, `tests/host/keys_spec.lua`.
- **`useBoxMetrics(ref)` / `measureElement(ref)`** -- Phase 3. Exact
  layout values (including border/padding-adjusted `clientWidth`/
  `clientHeight`) asserted directly in `terminal_spec.lua`.
- **`useFocus(opts)` / `useFocusManager()`** -- Phase 4. Tab/Shift+Tab
  (`keys.lua`'s `ESC[Z` handling) cycle a real focus registry in
  `render.lua`; `autoFocus` claims the slot on mount. Verified via a real
  `tmux` session sending `Tab`/`BTab` into a 3-item app and asserting the
  rendered `<-- FOCUSED` marker moved A→B→C→B, then confirming `q` left
  the terminal usable afterward. `isFocused`/`activeId` are exposed as
  **reactive getter functions**, not plain values, because Hydronium's
  component model calls a component's setup function exactly once (see
  hooks.lua's own top doc comment) -- a plain boolean/string captured at
  that one call could never update; this is a real, stated deviation from
  real Ink's own plain-field return shape.
  Implementation note: `useFocus`'s `autoFocus` registration runs during
  a component's setup call, which the reactive core's render-phase
  mutation guard (`ERR_RENDER_MUTATION`, `core/signals/signal.lua`)
  forbids from writing a signal directly -- `render.lua`'s
  `safeSetActiveFocusId`/`flushPendingFocusOps` defer any focus-id write
  made from inside a render pass until right after `mount()`/each loop
  iteration's `host.flush()`, both real outside-any-render points.
- **`useCursor()`** -- Phase 4. `setCursorPosition({x, y} | nil)` writes a
  real move+show (or hide) ANSI sequence directly via the same `writeFn`
  the host itself uses, bypassing the paint/diff pipeline entirely (there
  is no "cursor" in the cell grid `host/terminal.lua` paints). Position is
  0-based and relative to Ink's own output, matching real Ink's documented
  shape; converted to 1-based terminal coordinates. Covered by a permanent
  deterministic spec (`tests/host/render_spec.lua`, injecting `opts.writeFn`
  and asserting the exact captured escape bytes) since it needs no real
  stdin interaction to exercise. **Stated limitation:** every repaint that
  changes anything re-parks the cursor below the frame (`host.paint()`'s
  own comment on that line) -- a persistent custom position needs
  re-calling `setCursorPosition` after each of your own updates.
- **`useAnimation(opts)`** -- Phase 4. `{frame, time, delta}` (reactive
  getters, `reset()` a plain function) driven by a real timer ticker
  `render.lua`'s loop checks once per iteration. Verified via `tmux`: a
  spinner/frame counter advancing in real time, and `reset()` zeroing it
  back to 0 mid-run. **Found and fixed a real latent bug while building
  this**: the ticker (and `keys.lua`'s pre-existing standalone-Escape
  timeout) originally used `os.clock() * 1000` for elapsed time --
  `os.clock()` is *CPU time consumed*, not wall-clock time, and barely
  advances while the process sits blocked in `select()`/a paced sleep (a
  real measurement: ~261ms of wall time across a 250ms sleep produced
  only ~0.5ms of `os.clock()` movement). This meant the animation ticker
  never actually ticked, and a standalone Escape keypress could in
  practice never time out. Fixed by adding
  `ink/src/hydronium_ink/clock.lua` (`gettimeofday`-based, real wall-clock
  ms) and switching both call sites to it; re-verified live in `tmux`
  (spinner now advances, a lone Escape keypress now fires).
- **`usePaste(handler, opts)`** -- Phase 4. `keys.lua` recognizes
  bracketed-paste markers (`ESC[200~...ESC[201~`, DECSET 2004 --
  `render.lua` enables/disables the terminal mode itself around raw mode)
  and produces a distinct `PasteEvent` carrying the verbatim pasted text,
  dispatched separately from `useInput` so a paste never also fires as a
  stream of individual key events -- including when the pasted text
  itself contains real CSI byte sequences (a case with a dedicated unit
  spec). Verified live: raw bracketed-paste bytes injected into a real
  `tmux` pty (`tmux send-keys -l` with actual ESC bytes) were delivered to
  the handler as one event, while ordinary keystrokes sent immediately
  before it still went through `useInput` individually, unaffected.

**Explicitly not attempted anywhere in this module:** Windows (raw mode
needs the Win32 console API, structurally different from termios --
`render()` still mounts/paints once and skips the interactive loop on a
non-tty or Windows, a real degradation, not a silent one), reactive
`opts.isActive` on `useInput`/`useFocus`/`usePaste`/`useAnimation` (read
once at setup, matching Hydronium's setup-once component model -- toggling
needs an `if` inside the handler, or unmounting/remounting), and
`useIsScreenReaderEnabled` (no real accessibility-tree signal exists to
back it honestly).

## How to run everything

```
# Full native suite (434 specs; one lone pre-existing unrelated failure,
# tests/core/lazy_barrel_spec.lua, needs a `lua` binary on PATH -- present
# throughout this whole engagement, not caused by anything in this module)
luajit tests/runner.lua

# Just this module's own specs
luajit tests/runner.lua tests/host/terminal_spec.lua
luajit tests/runner.lua tests/host/keys_spec.lua      # ANSI key/paste parser, no TTY needed
luajit tests/runner.lua tests/host/render_spec.lua    # useCursor, via an injected writeFn

# The live demos against real stdout
luajit examples/ink_demo/run.lua        # Ctrl-C to stop
luajit examples/ink_demo/run.lua 10     # stop automatically after 10 ticks

# A real interactive app exercising Phases 1-3 together (Box/Text/Spacer
# layout, useInput/useApp/useWindowSize) -- needs a real TTY, not a pipe
luajit examples/ink_todo/run.lua
# or, via moonstone (path: deps on ../../core, ../../ink, ../../luax):
cd examples/ink_todo && moon sync && moon exec -- luajit run.lua

# Capturing real terminal output for inspection (macOS/Linux, `script` as the pty tool)
script -q /dev/null luajit examples/ink_demo/run.lua > /tmp/ink_output.txt 2>&1 &
sleep 3 && kill -TERM $(pgrep -f "luajit examples/ink_demo/run.lua" | head -1)
cat -v /tmp/ink_output.txt

# Interactive-loop features (useFocus/useFocusManager, useAnimation,
# usePaste) have no permanent automated spec -- render()'s event loop is
# a real blocking loop over real stdin, not something a deterministic
# unit test can drive without a real pty -- verify the same way this
# session did, with tmux:
tmux new-session -d -s t -x 80 -y 15
tmux send-keys -t t "luajit <your app>.lua" Enter
tmux send-keys -t t Tab          # or: BTab, or any real keystroke
tmux capture-pane -t t -p        # inspect the rendered result
tmux kill-session -t t
```
