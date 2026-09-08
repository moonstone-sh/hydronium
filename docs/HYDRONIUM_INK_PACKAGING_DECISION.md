# Hydronium Ink: packaging decision (workspace member vs. separate repo)

Written to this repo's own standard (`CLAUDE.md`, "Trust issue in `docs/`"):
every claim below is either backed by a command I actually ran in this
working tree, or is explicitly labeled as reasoning/unverified. Where a
prior doc's claim did not survive re-checking, that is said plainly.

Investigated 2026-09-08 against the live, **uncommitted, mid-migration**
working tree.

---

## 1. Recommendation

**Make `hydronium-ink` a fourth `orbits` workspace member inside this
repo — not a separate repo. Not yet.** Revisit externalization once (a)
the Host contract is frozen and (b) Ink has input handling and real
layout.

**This disagrees with the prior audit.** `docs/HYDRONIUM_PACKAGE_SPLIT.md`
lists `hydronium-ink` as "(separate repo, not a workspace member)" and
Step 5 as "externalize into its own repo." I re-derived the question from
the code and reached a different answer on the *repository* boundary.

To be precise about what I agree and disagree with:

| Prior audit claim | My finding |
|---|---|
| Ink should be its own **package**, not part of core | **Agree**, strongly — and the evidence is stronger than the audit stated (see §2.3) |
| Ink's code is already decoupled enough to move | **Agree** — verified end-to-end (§2.4) |
| Ink should be its own **repo** | **Disagree** — the stated justification does not hold up (§3) |
| Step 5 can happen soon | **Disagree on sequencing** — the tree is currently red (§4) |

**Confidence: ~75%.** Moderate-high, not high. This is a genuinely
reversible, low-stakes decision in both directions, which is itself part
of the argument for taking the lower-friction option now.

### Steelman for the alternative (separate repo)

The strongest case against me, stated fairly:

> A host adapter that lives in the framework's own monorepo is never
> really tested as a third-party integration. Being in-tree means it can
> quietly acquire a dependency on a core internal, get fixed in the same
> commit as the core change that broke it, and slowly become
> load-bearing on things core never promised. The whole architectural
> point of Ink is the claim "core is host-agnostic enough that an
> outsider can build a host against it." A workspace member with a path
> dependency and shared CI is not an outsider. Externalizing it now,
> while it is small (678 lines total) and has no users, is the cheapest
> this move will ever be — and every month it stays in-tree, the
> ratchet tightens.

That argument is real and it is why my confidence is 75% and not 95%.
My answer to it is in §3.3: the coupling-ratchet risk is real, but it is
better addressed by a **mechanical isolation guard** (which I have
already demonstrated works, §2.4) than by paying cross-repo lockstep
costs on the least-finished component in the repo.

---

## 2. Technical basis — what I actually verified

### 2.1 Where the code physically lives right now

Verified via `find` and `ls`. The prompt's expectation was correct:

```
core/src/hydronium/ink/init.lua          78 lines
core/src/hydronium/host/terminal.lua    600 lines
tests/host/terminal_spec.lua            396 lines
examples/ink_demo/run.lua                93 lines
```

Ink is **inside the `core` package's source tree**. It is not a member,
not a directory of its own, and `hydronium/moonstone.toml` has exactly
three `[[orbits.member]]` entries (`core`, `luax`, `dom`) — confirmed by
reading the file.

### 2.2 The "zero coupling" claim, re-checked

The package-split doc says Ink depends "on nothing but `hydronium.core.*`/
`hydronium.signals.*` (`host/terminal.lua` has zero `require` statements
at all)."

**`host/terminal.lua`: verified true.** `grep` returns two matches for
`require`, and I read both — line 33 and line 508 are inside doc
comments (the English word "requires"/"required"). A regex for actual
non-comment `require(` calls returns nothing. 600 lines, zero imports,
pure stdlib. This is genuinely as decoupled as a module gets.

**`ink/init.lua`: two real requires**, which the audit's summary phrasing
glosses over:

```lua
local symbols       = require("hydronium.core.symbols")
local elementModule = require("hydronium.core.element")
```

These are core **internals**, not a public API. There is no public
"create an intrinsic descriptor" surface; Ink reaches into
`core.symbols`/`core.element` directly.

**The decisive mitigating fact, which the audit does not mention:**
`dom/src/hydronium_dom/dom/init.lua` requires *exactly the same two
modules*, verified by grep — same names, same order. So Ink's coupling
to core is not merely "small," it is **byte-for-byte the same shape as
the DOM package's**, and the DOM package is already being shipped as a
separate `kind = "lib"` package with a path dependency on core. Whatever
resolution story works for `hydronium-dom` works unchanged for
`hydronium-ink`. This is a solved problem in this repo, not a new risk.

### 2.3 Ink is currently shipped to every core consumer (the real problem)

This is the strongest argument for splitting Ink out of `core`, and it is
an argument the prior audit did not make. Verified by `ls`:

```
dom/.moonstone/env/share/lua/5.4/hydronium/ink
dom/.moonstone/env/share/lua/5.4/hydronium/host/terminal.lua
```

Because Ink sits under `core/src/hydronium/`, `moon sync` materializes a
terminal renderer and its ANSI escape machinery into the environment of
**every** consumer of the `hydronium` package — including
`hydronium-dom`, i.e. including every browser/SSR application. That is
already happening today, on disk, in this repo. It is dead weight and a
confusing public surface (`require("hydronium.ink")` resolves in a web
app). Splitting Ink into its own package fixes this. Splitting it into
its own *repo* is not required to fix it.

### 2.4 Ink genuinely works against core alone — proven twice

I did not take this on faith. Two real runs:

**(a) In-tree isolation.** `package.path` restricted to `core/src` only —
no `dom/src`, no `luax/src`:

```
bytes: 161
dom loaded? false | luax loaded? false
```

It emitted a real ANSI frame (verified via `cat -v`: `\27[2J\27[H`, real
U+250C/U+2500 box-drawing UTF-8, `\27[1m\27[36m` bold-cyan). The module
census showed only `hydronium.core.*`, `hydronium.signals.*`,
`hydronium.test.*`, `hydronium.ink`, `hydronium.host.terminal` loaded.

**(b) Full external-package simulation.** I built a scratch project in
`/tmp` (since deleted; the repo working tree was not touched) with:

```toml
[package]
name = "hydronium-ink"
kind = "lib"

[[dependencies]]
name = "hydronium"
constraint = "path:/Users/extrordinaire/Workbench/user/hydronium/core"
registry = "path"
role = "runtime"
```

Copied `ink/init.lua` and `host/terminal.lua` into it **unmodified**
under a `hydronium_ink` namespace, ran `moon sync` (which materialized
the full core tree into `.moonstone/env/share/lua/5.4/hydronium/`), then
`moon exec -- lua probe.lua`:

```
bytes: 189
core came from dependency graph: true
```

Real green-on-border ANSI frame. **Conclusion: the audit's claim that
`host/terminal.lua` "needs no code changes" to be externalized is
correct, and I extend it — `ink/init.lua` needs no changes either.** Its
`hydronium.core.*` requires resolve fine through the real moonstone
dependency graph.

This matters for the recommendation in a way the audit missed: **I
reproduced the entire "third party builds a host on core alone" proof in
about five minutes, from outside the repo, using a path dependency.**
The proof does not require a permanent separate repo. It requires a
scratch directory and a `moon sync`.

---

## 3. Why a workspace member, not a separate repo

### 3.1 The audit applies its own principle inconsistently

The package-split doc justifies keeping core and DOM in one workspace:

> core and DOM co-evolve today (recent HMR/DOM-host work touched both
> simultaneously) and shouldn't pay a publish-cycle tax for that.

That is a good principle. It applies to Ink **with more force than to
DOM**, not less. From Ink's own doc (`HYDRONIUM_INK_TERMINAL_HOST.md`,
"Explicitly NOT implemented" and the ground-truth table), Ink currently
has:

- no keyboard input / `useInput` equivalent (NOT ATTEMPTED)
- no flexbox grow/shrink/justify/align (NOT IMPLEMENTED)
- no text wrapping (NOT IMPLEMENTED)
- no awareness of real terminal size (NOT IMPLEMENTED)

Adding any one of those is a substantial, likely breaking change. Ink is
the **least finished** component in the repo. The audit's own
"co-evolution means don't pay a publish tax" reasoning selects Ink as the
*last* thing you would put behind a cross-repo boundary, not the first.

### 3.2 The Host contract is not frozen

Step 6 of the same tracker — rename `domNode` → `hostNode` in
`core/reconciler.lua` / `core/component.lua` hydration signatures — is
still open and unchecked. That is a change to the surface every host
implements. Separately, Ink's doc documents a real defect it had to work
around: `reconcileChildren()` unconditionally re-`appendChild`s every
child on every reconcile, which forced Ink's whole dirty-flag/`flush()`
design. That is a core behavior that a future core change could
legitimately fix — and doing so would want a coordinated Ink update.
In-repo, that is one commit. Cross-repo, it is a version bump, a publish,
a lockfile update, and a window where the two are out of sync.

### 3.3 The "prove it as a third party" benefit is obtainable without a repo split

This is the audit's headline justification, and it is the one I think
does not survive scrutiny. As shown in §2.4, the third-party proof is a
scratch project + path dependency, and it takes minutes. It can be made a
**standing** check rather than a one-off, using the exact technique this
repo already uses for its other architectural guards
(`tests/core/lazy_barrel_spec.lua`, `tests/luax/no_core_coupling_spec.lua`):
spawn a fresh interpreter with `package.path` restricted to
`ink/src` + the materialized core, require Ink, render a frame, and
assert that nothing under `hydronium_dom.*` or `hydronium_luax.*` ever
enters `package.loaded`.

That guard gives you the anti-ratchet protection the steelman (§1) is
actually worried about, at near-zero cost, without the cross-repo tax.
A separate repo buys a *symbolic* claim; the guard buys the *enforceable*
one.

**Caveat, stated honestly:** I did not write that guard. I demonstrated
that the mechanism it would rely on works (§2.4 (a) and (b)); I did not
implement or run the spec itself.

### 3.4 A caution about the existing guards

While establishing a baseline I found that this repo's existing
isolation guards are **currently failing**, and one of them is
methodologically unsound. `tests/luax/no_core_coupling_spec.lua`:

- Spec 1 ("loads without core or DOM in a fresh process") fails with
  `sh: lua: command not found` — it shells out to a bare `lua`, which is
  not on `PATH`; the interpreter now lives inside the moonstone env, so
  this needs `moon exec`.
- Spec 2 ("compiles real LUAX without core") does
  `assert.falsy(package.loaded["hydronium"])` **in-process**, after other
  specs in the same run have already loaded core. It therefore measures
  spec execution order, not isolation — which is precisely the mistake
  the package-split doc itself correctly identifies and avoids for
  Step 1's guard. It currently fails for that reason.

`tests/core/lazy_barrel_spec.lua` fails the same `lua: command not found`
way. So the "standing regression test" credited in Step 3 is not
currently standing. If you adopt my §3.3 recommendation, write the Ink
guard as a genuinely fresh `moon exec` subprocess, not an in-process
`package.loaded` check.

---

## 4. Sequencing — what to do, in what order

### 4.1 The tree is red right now. Verified.

`luajit tests/runner.lua` on the current working tree:

```
SUMMARY: 393 Total | 353 Passed | 40 Failed | Duration: 0.086 s
```

The package-split doc's stated baseline ("394/394 passing as of Step 3")
is **stale** — it describes the pre-migration tree, not this one. Failure
distribution by file:

| File | Failures | Cause (from error text) |
|---|---|---|
| `tests/server/server_spec.lua` | 36 | `attempt to index field 'server' (a nil value)` — barrel/namespace fallout from the DOM split |
| `tests/luax/no_core_coupling_spec.lua` | 2 | see §3.4 |
| `tests/core/dom_descriptors_spec.lua` | 2 | `attempt to call field 'renderToString' (a nil value)` |
| `tests/server/ssr_spec.lua` | 1 | `attempt to index field 'd' (a nil value)` |
| `tests/core/lazy_barrel_spec.lua` | 1 | `lua: command not found` |

**All 5 `tests/host/terminal_spec.lua` specs pass.** Verified by name in
the run output. Zero Ink failures. Every failure is core/dom/luax split
collateral.

Also stale and confirmed broken, independent of Ink:
- `.luarc.json` still points its LuaLS plugin at
  `src/hydronium/luax/lua/hydronium/init.lua`; `src/` is now an **empty
  directory** (verified with `ls -la src/`).
- `examples/ink_demo/run.lua` **does not run**. Verified:
  `luajit examples/ink_demo/run.lua 3` →
  `module 'hydronium' not found`. Its `package.path` is still
  `"src/?.lua;src/?/init.lua;..."`, the pre-migration layout. This is
  already broken in the working tree and needs fixing whether or not Ink
  moves.

### 4.2 Recommended order

**Do not touch Ink in the current pass.** Ink is the only fully-green
subsystem in a tree with 40 failures. Folding a green subsystem into a
red restructuring destroys your ability to attribute any new breakage.

1. **Land the current core/dom/luax orbits split.** Get
   `luajit tests/runner.lua` back to green, fix `.luarc.json`, fix
   `examples/ink_demo/run.lua`'s `package.path` (one line — change
   `src/` to `core/src/`), commit. Update
   `docs/HYDRONIUM_PACKAGE_SPLIT.md` to check Step 4 and correct the
   stale suite baseline.
2. **Then** move Ink to a fourth member, as its own commit, with a green
   tree on both sides of it. §5 has the mechanics.
3. **Then** add the isolation guard from §3.3.
4. **Defer** the separate-repo question until Ink has input handling and
   the Host contract is settled (i.e. after Step 6). Re-open it then, on
   evidence, not on schedule.

### 4.3 What breaks when Ink moves (complete list, from grep)

I grepped the whole repo for `hydronium.ink`, `host.terminal`,
`host/terminal`, `ink_demo`, and `tests/host`, excluding `.git` and
`.moonstone`. Everything that needs touching:

| File | Change needed |
|---|---|
| `tests/runner.lua:5` | `package.path` — add `ink/src/?.lua;ink/src/?/init.lua;` |
| `tests/runner.lua:402` | registration entry `"tests/host/terminal_spec.lua"` — keep or repoint if the spec moves into `ink/tests/` |
| `tests/host/terminal_spec.lua:25-26` | `require("hydronium.ink")` → `require("hydronium_ink")`; `require("hydronium.host.terminal")` → `require("hydronium_ink.host.terminal")` |
| `examples/ink_demo/run.lua:33,47-50` | `package.path` (already broken) + the same two require renames |
| `docs/HYDRONIUM_INK_TERMINAL_HOST.md` | file paths in "Files:" and the ground-truth table still say `src/hydronium/...` |
| `docs/HYDRONIUM_PACKAGE_SPLIT.md` | Step 5 wording, and the boundary table row |
| `hydronium/moonstone.toml` | add the fourth `[[orbits.member]]` |

Nothing in `core/`, `dom/`, or `luax/` source references Ink at all —
verified. The blast radius is tests, one example, two docs, and the
workspace manifest. That is small, and it is another reason this is not
an urgent or risky move in either direction.

**Note a real (but free) API break:** following the established
convention, `require("hydronium.ink")` becomes `require("hydronium_ink")`.
Ink has no external consumers today, so this costs nothing now and would
cost more later. That is a mild argument for doing the member move
sooner rather than deferring it indefinitely.

---

## 5. Concrete how-to (the recommended path: fourth orbits member)

Modeled on the two working precedents I read: `alter/toml-backend/` (a
real, published orbit member) and this repo's own `dom/`.

### 5.1 Directory move

Match the sibling convention exactly (`dom/src/hydronium_dom/`,
`luax/src/hydronium_luax/`):

```
ink/
  moonstone.toml
  partiture.lua                       # only when you actually publish
  src/hydronium_ink/
    init.lua                          # from core/src/hydronium/ink/init.lua
    host/terminal.lua                 # from core/src/hydronium/host/terminal.lua
  tests/                              # optional: move terminal_spec.lua here
  examples/ink_demo/run.lua           # optional: move with it
```

Use `git mv` so the renames stay reviewable, consistent with how the
core/dom/luax moves are staged today.

### 5.2 `ink/moonstone.toml`

Directly parallel to `dom/moonstone.toml`, which I read:

```toml
manifest_version = 2

[package]
name = "hydronium-ink"
version = "0.1.0"
kind = "lib"
description = "Hydronium Ink: terminal host adapter and Box/Text/Newline intrinsics"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[[dependencies]]
name = "hydronium"
constraint = "path:../core"
registry = "path"
role = "runtime"

[scripts]
test = "lua ./tests/runner.lua"
```

`kind = "lib"` is mandatory — per the package-split doc's "decisive
finding," `kind = "script"` packages are not materialized into
consumers, which was the actual root cause of the earlier false "no Lua
dependency graph works" conclusion.

### 5.3 Register the member

Append to `hydronium/moonstone.toml`:

```toml
[[orbits.member]]
name = "ink"
path = "ink"
```

Then `moon orbit sync` (or `moon sync` at the workspace root). Verify
with `moon orbit list` and by checking that
`ink/.moonstone/env/share/lua/5.4/hydronium/` appears — that is the
proof core resolved through the real graph, exactly as I confirmed in
§2.4 (b).

### 5.4 Verify

```bash
cd ~/Workbench/user/hydronium
luajit tests/runner.lua                          # expect green, 5 terminal specs among them
luajit examples/ink_demo/run.lua 10              # real ANSI frames on stdout
cd ink && moon sync && moon exec -- lua -e 'print(type(require("hydronium_ink")))'
```

The last line is the one that actually proves the package boundary; the
first two only prove the in-tree paths still work.

### 5.5 If you later decide to externalize after all

Recorded here so the option stays cheap, and because §1 gives it real
odds. The steps, using the `moon` workflow and
`LOCAL_DEV_FLOW.md`'s recipe:

1. `git filter-repo` (or a plain copy plus a fresh `git init`) of `ink/`
   into its own repo. The manifest needs one change: swap the path
   dependency for a registry one.
2. During development, keep the fast loop — in the ink repo,
   `moon link --name hydronium-ink`, and in any consumer
   `moon add link:hydronium-ink`. No registry, no version bump.
3. To test real distribution before any remote registry exists, use the
   local registry that already exists at
   `~/Workbench/user/local-registry` (verified present: `registry.toml`,
   `index.toml`, `packages/`, `blobs/`). Add a `partiture.lua` modeled
   on `alter/toml-backend/partiture.lua`, which I read — for Ink it
   would be:

   ```lua
   local ballad = require("ballad")
   return ballad.partiture(function(p)
       local moonstone = p:use(ballad.plugins.moonstone)
       local convention = ballad.conventions
       local project = moonstone.project({ root = "." })
       local artifact = moonstone.registry.source_package(project, {
           readme = "REGISTRY_README.md",
           collect = {
               lua_modules = {
                   convention.tree("src", {
                       prefix = "hydronium_ink",
                       strip_prefix = "hydronium_ink/",
                       root_module = "hydronium_ink.lua",
                   }),
               },
           },
       })
       p.sink.artifact(artifact, { out = "dist/registry", product = "package" })
   end)
   ```

   Then:

   ```bash
   moon exec ballad play partiture.lua
   moon registry push ~/Workbench/user/local-registry \
     --descriptor dist/registry/hydronium-ink/package.toml \
     --blob dist/registry/hydronium-ink/hydronium-ink-0.1.0-source.tar.zst \
     --replace --yes

   cd ~/Workbench/user/<consumer>
   moon registry add test-local file:///Users/extrordinaire/Workbench/user/local-registry --default
   moon add test-local:hydronium-ink@0.1.0 --update
   ```

   Iterate on **one** version via `--replace --yes` + `moon sync --force`;
   per `LOCAL_DEV_FLOW.md`'s release discipline, do not tag git or burn
   micro-versions while still iterating locally.

   **Not verified:** I did not run `ballad play` for Ink and there is no
   `partiture.lua` anywhere in the hydronium repo today (checked — only
   `alter/` has them). The partiture above is written by analogy to
   `alter/toml-backend/partiture.lua`, not tested. `hydronium-ink` would
   also need a `REGISTRY_README.md`, which does not exist.

---

## 6. What I did not check

Stated plainly, per this repo's norm:

- I did **not** run `moon orbit add`/`moon orbit sync` against the real
  repo — the working tree is mid-migration and uncommitted, and I was
  scoped to read-only. The §2.4 (b) proof used a throwaway `/tmp`
  project instead (since deleted). The repo working tree is unmodified
  by me apart from this new doc; `git status --porcelain` still reports
  the same 168 entries.
- I did **not** run `ballad play` or push anything to
  `~/Workbench/user/local-registry`. I confirmed the registry exists and
  read its `registry.toml`; its `packages/` currently holds only
  `moonstone/ballad-watch` and `moonstone/meteorite`.
- I did **not** diagnose or fix the 40 failing specs. I characterized
  them by file and error text only; I did not confirm that every one is
  purely migration fallout, though the error shapes (`field 'server' is
  nil`, `field 'd' is nil`, `renderToString` nil) are all consistent
  with the DOM/barrel split being incomplete.
- I did **not** re-verify Ink's rendering claims beyond mounting and
  painting two frames. I did not re-run the pty capture, and I did not
  independently re-check the diffing, `Newline`, or unmount behaviors
  beyond observing that their specs pass.
- I did **not** examine `hydronium-create`, which the package-split doc
  says still carries a symlink workaround that Step 0 made removable.
- I read `alter/moonstone.toml`, `alter/toml-backend/moonstone.toml`, and
  `alter/toml-backend/partiture.lua`. I did not run `alter`'s build or
  tests.
- I did not read `~/Workbench/user/moonstone/docs/`; the manifests and
  the live `moon sync` behavior answered what I needed.

---

## 7. Summary

Ink should stop being part of `core` — that much is unambiguous, and the
evidence is a terminal renderer currently materialized into every web
consumer's environment (§2.3), which I confirmed on disk.

But "stop being part of core" and "live in another repo" are two
different decisions, and the prior audit merges them. The packaging
boundary is worth having now. The repository boundary buys one symbolic
benefit that a five-minute scratch project already delivers (§2.4), and
charges for it in cross-repo lockstep on the single least-finished,
most-likely-to-change component in the tree — against a Host contract
that Step 6 has not even finished renaming.

Make it a member. Add the isolation guard. Revisit the repo split when
Ink is finished enough that its version numbers would mean something.
