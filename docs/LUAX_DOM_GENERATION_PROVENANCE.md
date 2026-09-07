# LUAX DOM Type Data Provenance

## Current supportable claim

`tools/dom_generator/webref_data.lua` is a **curated local schema snapshot**.
`tools/dom_generator/init.lua` deterministically emits the checked-in LuaCATS
files from that snapshot. The generator is real, but it does not download,
parse, pin, or checksum an installed `@webref/*` package. Consequently it is
incorrect to call the current files a direct or reproducible WebRef import.

The snapshot was informed by public platform references (WHATWG HTML, DOM/UI
Events, ARIA, and WebRef as a reference source), but no upstream version,
archive digest, or transformation manifest is recorded in this repository.
Element/event coverage is intentionally partial and must be treated as such.

## Reproducible local generation

The local source-to-output operation is deterministic:

```bash
moon exec lua -e 'require("tools.dom_generator").run("types")'
```

It writes `types/dom/events.d.lua`, `html.d.lua`, `svg.d.lua`,
`intrinsics.d.lua`, and `types/luax.d.lua`. Review the resulting diff; this
operation does not establish external provenance.

## Required work before claiming WebRef provenance

An upstream-backed pipeline needs all of the following:

1. a pinned `@webref/*` package version and content digest;
2. a checked-in import/normalization program;
3. a source manifest recording package/version/digest and generated files;
4. a regeneration test that verifies the manifest and output determinism; and
5. explicit handling for Hydronium-specific synthetic events and deliberate
   deviations from Web platform IDL.

Until then, consumers should rely only on the local schema and its tests.
