# Hydronium Hardening Audit — 2026-09-06

## Scope and evidence

This audit preserved existing working-tree work and examined Hydronium's live
SSR/LUAX paths plus the adjacent `../meteorite` repository. It is deliberately
not a release approval.

Initial full Lua suite: **306 passed, 0 failed** under `moon exec lua
tests/runner.lua`. The count is runtime-dependent only insofar as test files
are present; it is not a claim about external editor tooling.

After the SSR ownership/security tests were added, the full suite was rerun:
**311 passed, 0 failed**. The standalone Neovim script also passed **5/5**.

## SSR finding and repair

The server renderer was already independent of Meteorite at module load time,
but its ownership and state-serialization boundaries were incomplete:

- A component scope was disposed before recursively rendering its returned
  subtree. Nested component scopes therefore attached to the root rather than
  their rendering parent.
- Scope-disposal failures could interrupt root restoration.
- State JSON accepted arbitrary tables/values, did not reject cycles or
  non-finite numbers, and could emit a literal `</script>` from state.
- Tag and attribute names were trusted as already safe.

The renderer now renders a component subtree while that component's scope is
active, then disposes it. Root/scope/context/scheduler restoration occurs even
when disposal fails. `server/json.lua` accepts only JSON data, sorts object
keys, rejects cycles/non-finite/unsupported values, and escapes HTML-sensitive
characters in JSON strings. `server/sink.lua` owns the synchronous sink
normalization and guarantees close is attempted after a render failure.

The SSR contract remains synchronous and non-yielding. It does not make the
global scheduler/context stacks coroutine-local; callers must not interleave
or yield from a render.

## LUAX and environment findings

The compiler supports explicit `---@luax environment <alias>` bare-tag alias
lowering and explicit `options.env`; this is the supportable per-file choice.
`environment.set_current` remains process-global compatibility state, so it
is not a concurrency-safe project environment selector. Projects needing
isolation should pass `options.env` or use a lexical `d` alias/pragma rather
than mutate the ambient environment.

The DOM data document now correctly describes the checked-in schema as a
curated snapshot, not a pinned WebRef import.

## LuaLS result

The harness now discovers LuaLS instead of assuming one hard-coded path and
reports both unavailable servers and transport failures explicitly. In this
environment LuaLS was available, but callback hover typing returned `unknown`
and a later hover request timed out. Completion passed; event/ref typing,
definition, rename, diagnostics, and latency are gated pending a clean live
run. See `LUAX_LSP_E2E_VERIFICATION.md`.

## Meteorite compatibility audit

Meteorite is a compiler whose hybrid handlers expose `c:html`, `params`,
`query`, `state`, `scope`, and `c:request_id()` in its documented runtime
contract. Hydronium's optional adapter uses only those documented shapes and
is lazy-loaded, so importing `hydronium.server` does not import Meteorite.

No Meteorite files were changed. Hydronium tests use contract doubles, not a
compiled Meteorite server; they establish adapter shape compatibility only.
An actual end-to-end vertical slice is gated on packaging Hydronium into a
Meteorite hybrid app and exercising the generated Zig/Lua bridge. It must not
be represented as complete until that external integration is run.
