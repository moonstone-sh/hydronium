# Versioning

Hydronium releases every package together, under one version number. The
repository tag, the root `moonstone.toml` and every `hydronium/*` package
carry the same version, and a generated project depends on all of them with
the same floor.

## Why lockstep

Inside the workspace every dependency is `path:`. The export turns each one into
`^<that member's version>`. While Hydronium is below 1.0, `^0.3.0` excludes
`0.4.0`, so a breaking change to a package that others depend on forces every
dependent to be republished with a new floor. Releasing v0.4.0 that way bumped 16
of 18 packages by hand and rewrote more than 40 floors in `create`. With one
version for everything, that bookkeeping disappears: a user picks one Hydronium
version, and every floor, constraint and doc page agrees on it.

The cost is that a package with no changes is republished under the new version.

## The rules

- The root `moonstone.toml` `[package] version` is the release version.
- Every member's `[package] version` equals it.
- Every `hydronium/*` floor that `create` writes into a generated project is
  `^<version>`, and so are the literal copies its tests assert.
- `hydronium-create --version` and the CLI's `M.VERSION` report it.
- Versions change only through `tools/version.lua`, at release time.
- Semantic versioning, read the 0.x way: a minor bump (`0.7.0` → `0.8.0`) may
  break; a patch bump (`0.7.0` → `0.7.1`) must not.

## Cutting a release

```sh
git switch -c release/v0.8.0 origin/main
moon exec -- luajit tools/version.lua set 0.8.0
moon exec -- luajit tests/runner.lua
(cd create && moon sync && moon run test)
```

`set` rewrites the root manifest, every member manifest, `create`'s floors and
test literals, and the CLI constants, then runs `check --lockstep` itself.
Commit, open a PR, merge it, and tag the merge commit `v0.8.0`. The release
workflow refuses to publish when the tag differs from the root version or when
any copy disagrees.

`moonstone/*` dependencies in `create`'s templates (Meteorite, Ballad) are other
projects' versions and stay as written.

## Checks

| check | where | what it enforces |
|---|---|---|
| `tools/version.lua check` | `tests/build/versions_spec.lua`, every test run | `create`'s floors and the CLI constants equal the member manifests |
| `tools/version.lua check --lockstep` | release workflow, tags from `v0.7.0` | additionally, every member equals the root version, which equals the tag |

## History

Before v0.7.0 each package had its own version and the repository tag was a
release counter (v0.4.0 shipped core 0.3.0, dom 0.4.0, create 0.6.0). The first
lockstep release is v0.7.0, at or above every package's previous version so
that nothing moves backwards.
