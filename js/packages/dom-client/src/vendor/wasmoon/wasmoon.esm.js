/*
  wasmoon 1.16.0 -- ES module wrapper over the vendored, UNMODIFIED
  upstream bundle (`./index.js`).

  PROVENANCE. `./index.js`, `./glue.wasm` and `./LICENSE` are byte-for-byte
  the files inside the real published npm tarball, obtained with
  `npm pack wasmoon@1.16.0` (not scraped from a CDN, not hand-edited):

    index.js   sha256 dc2dcf019449008bb224370052473dc760db28b3ba14fc604e1ca3e8646af35d
    glue.wasm  sha256 95f3f19ddb740125883bc41d5ec670cd0828e7b58c8bdad385323cbff497b55c

  LICENSE: MIT (Copyright (c) 2023 Gabriel Francisco) -- see ./LICENSE,
  copied verbatim from the same tarball. MIT permits redistribution
  provided the notice travels with the code, which is why ./LICENSE is
  vendored alongside the two dist files rather than merely referenced.

  Upstream: https://github.com/ceifa/wasmoon

  WHY THIS FILE EXISTS. wasmoon publishes `dist/index.js` as a UMD bundle,
  not an ES module -- its `package.json` has a `main` and no `module`/
  `exports` ESM entry. `mount.js` loads wasmoon with a dynamic
  `import()`, and importing UMD directly is useless: with no `exports`,
  no `module` and no AMD `define` in scope, the UMD preamble falls
  through to its browser-global branch and assigns everything to
  `globalThis.wasmoon`, leaving the import namespace object completely
  empty -- `const { LuaFactory } = await import("./index.js")` yields
  `undefined`. Previously mount.js sidestepped this by importing
  jsdelivr's `/+esm` URL, which is jsdelivr's own on-the-fly UMD->ESM
  transform of this exact file; this module is that same adaptation done
  locally and legibly, so the bundle we ship is upstream's real artifact
  rather than a third party's rewrite of it.

  It deliberately leaves NO `globalThis.wasmoon` behind (this codebase
  treats accidental globals as a defect, see the bare-vs-lexical LUAX
  discussion in the repo docs): the UMD's global assignment is captured
  and whatever was there before is put back.

  NOTE ON THE .wasm. Loading this module does NOT fetch `./glue.wasm` --
  wasmoon only requests the binary when a `LuaFactory` is constructed,
  and where it requests it from is decided ENTIRELY by that constructor's
  first argument (`new LuaFactory(customWasmUri)`). Left undefined in a
  browser, wasmoon hardcodes `https://unpkg.com/wasmoon@<version>/dist/glue.wasm`
  -- a second, cross-origin round trip on every page load. `mount.js`
  therefore always passes an explicit URI; see its DEFAULT_WASMOON_WASM_URL.
*/

const previousGlobal = globalThis.wasmoon;
const hadPreviousGlobal = "wasmoon" in globalThis;

// Side-effect import: evaluating the UMD assigns its export table to
// `globalThis.wasmoon` (its browser-global branch, the only one reachable
// from an ES module).
//
// This is a DYNAMIC import with top-level await, not a static one, and
// that is load-bearing rather than stylistic: static `import` declarations
// are hoisted, so the whole dependency graph is evaluated before the
// first statement of this module body runs. With a static import the two
// lines above would therefore read `globalThis.wasmoon` AFTER the UMD had
// already overwritten it, capture wasmoon's own table as the "previous"
// value, and faithfully restore it -- silently leaving exactly the global
// this wrapper exists to avoid. Awaiting the import here instead keeps
// the capture genuinely before the write.
await import("./index.js");

const wasmoon = globalThis.wasmoon;

if (!wasmoon || typeof wasmoon.LuaFactory !== "function") {
  throw new Error(
    "hydronium vendor/wasmoon: ./index.js did not install its UMD global as expected " +
      "(no globalThis.wasmoon.LuaFactory). The vendored bundle may be truncated or replaced."
  );
}

// Undo the UMD's global write.
if (hadPreviousGlobal) {
  globalThis.wasmoon = previousGlobal;
} else {
  delete globalThis.wasmoon;
}

// Upstream's full public surface (matches dist/index.d.ts plus the enums
// re-exported from its ./types), so this file is a drop-in replacement for
// the CDN ESM build and not just a LuaFactory shim.
export const {
  Decoration,
  LUAI_MAXSTACK,
  LUA_MULTRET,
  LUA_REGISTRYINDEX,
  LuaEngine,
  LuaEventCodes,
  LuaEventMasks,
  LuaFactory,
  LuaGlobal,
  LuaLibraries,
  LuaMultiReturn,
  LuaRawResult,
  LuaReturn,
  LuaThread,
  LuaTimeoutError,
  LuaType,
  LuaTypeExtension,
  LuaWasm,
  PointerSize,
  decorate,
  decorateFunction,
  decorateProxy,
  decorateUserdata,
} = wasmoon;

export default wasmoon;
