# Package Split: core / dom / luax / ink (Migration Tracker)

Ground truth for the ongoing migration from one `hydronium` tree into a
host-agnostic core plus separate host/tooling packages. Plan and
evidence originally produced by an Opus-level architectural audit; this
doc tracks real progress against it as steps land, the same "don't
self-certify, keep the record honest" discipline as every other doc in
this directory.

## The decisive finding

An earlier audit of `hydronium-create` (the scaffolding CLI) concluded
no working precedent existed for resolving a Lua dependency through the
moonstone dependency graph, and had generated projects resolve
`require("hydronium")` via a checked-in filesystem symlink instead.
**That conclusion was wrong, verified two ways**:

```
$ cd hydronium/create && moon exec -- lua -e 'print(type(require("alter")), type(require("clingy")))'
table   table
```

`hydronium-create` already consumes two real libraries through the real
dependency graph. The mechanism: `moon sync` materializes a
`kind = "lib"` dependency's `src/` into the consumer's
`.moonstone/env/share/lua/<abi>/`, and `moon exec` points `LUA_PATH`
there. The actual blocker was narrower than "the mechanism doesn't
work": hydronium's own `moonstone.toml` declared `kind = "script"`, and
only `kind = "lib"` packages get materialized into a consumer's env.

## Recommended package boundaries

| Package | Contents |
|---|---|
| `hydronium` (core) | `core/*`, `signals/*`, `test/*`, `interpreter/lua.lua` |
| `hydronium-luax` | `luax/*`, tree-sitter grammar, VSCode extension, LuaLS plugin |
| `hydronium-dom` | `dom/*`, `host/dom.lua`, `client/*.js`, `server/*` (SSR + meteorite) |
| `hydronium-ink` (separate repo, not a workspace member) | `ink/*`, `host/terminal.lua` |

`hydronium` + `hydronium-luax` + `hydronium-dom` as a 3-member `orbits`
workspace (mirroring `/Users/extrordinaire/Workbench/user/alter/`'s
real, working structure) -- core and DOM co-evolve today (recent
HMR/DOM-host work touched both simultaneously) and shouldn't pay a
publish-cycle tax for that. `hydronium-ink` stays deliberately external:
it's already written depending on nothing but `hydronium.core.*`/
`hydronium.signals.*` (`host/terminal.lua` has zero `require`
statements at all), and its whole value as an architectural claim
("a third party can build a host on core alone") is best proven by
actually being a third party, not a workspace member.

## Migration steps

Each step is independently valuable and verified by the full native
suite (`luajit tests/runner.lua`) plus a step-specific check. No step
requires a later one to land.

- [x] **Step 0 -- flip the manifest.** `moonstone.toml`:
  `kind = "script"` &rarr; `"lib"`, interpreter `lua@5.4` &rarr;
  `luajit@2.1.0` (abi `5.1`, matching what the suite already runs
  under). Verified live with a real scratch consumer (`[[dependencies]]
  name = "hydronium" constraint = "path:../hydronium" registry = "path"
  role = "runtime"`): `moon sync` materialized
  `.moonstone/env/share/lua/5.1/hydronium/` with the full real source
  tree, and `require("hydronium")`, `require("hydronium.dom")`, and
  `require("hydronium.core.reconciler")` all resolved correctly with no
  symlink and no manual `package.path`. This alone is what makes the
  symlink workaround in `hydronium-create`'s templates removable
  whenever that repo is updated to depend on `hydronium` for real
  (not done yet -- a `hydronium-create`-side change, out of scope here).
- [x] **Step 1 -- delazify the barrel.** `src/hydronium/init.lua`'s
  `luax`/`server`/`ssr`/`renderToString`/`render_to_string`/`dom`/`d`
  fields are now resolved via an `__index` metamethod instead of eager
  `require(...)` calls in the table constructor -- `require("hydronium")`
  alone no longer touches `package.loaded["hydronium.dom"]`,
  `["hydronium.server"]`, or `["hydronium.luax"]` at all; each loads (and
  is cached) only on first actual access
  (`H.dom`/`H.d`/`H.luax`/`H.server`/`H.ssr`/`H.render_to_string`/
  `H.renderToString`), functionally identical to before for any caller
  that touches them. `core/`, `signals/`, and `luax/` were independently
  already free of any DOM/SSR requires -- this barrel was the ONLY real
  coupling forcing them together at load time. Verified for real (not
  just by reasoning about the code) via `tests/core/lazy_barrel_spec.lua`,
  which shells out to a genuinely fresh `luajit` process (the only way
  to check this honestly -- by the time any spec runs inside the shared
  test suite process, other specs have almost certainly already
  `require`d these modules directly, which would make an in-process
  `package.loaded` check measure execution order, not real laziness).
- [x] **Step 2 -- merge the Hydronium Ink terminal-host worktree.**
  `src/hydronium/host/terminal.lua`, `src/hydronium/ink/`,
  `tests/host/terminal_spec.lua`, `examples/ink_demo/`, and
  `docs/HYDRONIUM_INK_TERMINAL_HOST.md` folded into main (the worktree
  and its branch, `worktree-agent-a85635deaddfa26b3`, removed after
  verifying the merge). All three Host implementations --
  `hydronium.test.createTestHost` (in-memory), `hydronium.host.dom`
  (real browser DOM), and `hydronium.host.terminal` (real terminal) --
  now pass together in one suite run. Re-verified the live terminal
  demo for real from the merged tree (`script -q /dev/null luajit
  examples/ink_demo/run.lua`, inspected via `cat -v`): real ANSI escape
  sequences, real box-drawing UTF-8 bytes, a live counter ticking with
  single-cell diffs, unchanged after the merge.
- [x] **Step 3 (deferred split, decision + locked-in guard).** The
  physical move of `luax/` into its own package is deliberately
  DEFERRED to Step 4 -- done together with standing up the orbits
  workspace, so the directory only moves once instead of once now and
  again when the workspace is introduced. What *is* done now: the
  "zero real dependency on core" claim (the one
  `require("hydronium.dom")`-looking match in `luax/compiler/init.lua`
  is inside a comment, not code) is no longer just a one-time audit
  finding -- it's a standing regression test,
  `tests/luax/no_core_coupling_spec.lua`, using the same fresh-process
  technique as Step 1's guard: `require("hydronium.luax")` alone loads
  nothing under `hydronium.*` outside `hydronium.luax.*`, and compiling
  real `.luax` source doesn't pull in `hydronium.core` either. This
  means nothing can quietly reintroduce a core dependency into the
  compiler between now and whenever Step 4 actually happens.
- [x] **Step 4 -- introduce the orbits workspace.** Moved `luax/` (plus
  the tree-sitter grammar, VSCode extension, LuaLS plugin -- and update
  every path that references them: the Neovim plugin's `parser/luax.so`/
  `queries/luax/`, the VSCode extension, and every example's
  `.luarc.json` LuaLS plugin path) into `luax/` as `hydronium-luax` and
  namespace `hydronium_luax.*`; moved `dom/`, `host/dom.lua`, `client/`,
  `server/`, DOM declarations, and the client-manifest tool into `dom/` as
  `hydronium-dom` and namespace `hydronium_dom.*`. The root is now the
  Lua 5.4 `hydronium-workspace` orbits workspace with `core`, `luax`, and
  `dom` members; `dom` declares its actual path runtime dependency on core.
  Core owns `hydronium.*`; the old cross-package barrel aliases were removed.
  Real clean-consumer evidence: a consumer with all three `path:`
  dependencies ran `moon sync` and materialized exactly
  `hydronium`, `hydronium_luax`, and `hydronium_dom` under
  `.moonstone/env/share/lua/5.4`, then printed `split consumer: OK` after
  importing all three. The migrated native suite passed `393/393` through
  `moon exec -- lua tests/runner.lua`. The Meteorite SSR example was changed
  from its checked-in source symlink to real member dependencies; after
  `moon exec --dev meteorite graph ...` and `moon exec -- zig build ...`,
  the compiled server served `/` to curl and its real Playwright proof passed
  all five assertions, including two real clicks from `Count: 10` to
  `Count: 12`. Ink and `host/terminal.lua` remain temporarily in core so the
  already-merged terminal feature stays functional; Step 5 remains the
  separate externalization work.
- [ ] **Step 5 -- externalize `hydronium-ink`** into its own repo,
  depending on published/pathed `hydronium` alone. `host/terminal.lua`
  needs no code changes for this -- it's already written that way.
- [ ] **Step 6 (optional, cosmetic)** -- rename `domNode` &rarr;
  `hostNode` in `core/reconciler.lua`/`core/component.lua`'s hydration
  signatures; harmless as-is, just DOM-flavored naming in a
  host-agnostic file.

## Suite baseline

394/394 passing as of Step 3 (`luajit tests/runner.lua`).
