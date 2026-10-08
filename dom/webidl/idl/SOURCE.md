# Vendored WebIDL

`webgl1.idl`, `webgl2.idl` and `webgpu.idl` are copied unmodified from
[`@webref/idl`](https://www.npmjs.com/package/@webref/idl) 3.85.1
(tarball sha256 `96f52211243f69955c5d5722ac271d7fca7f4609a68f3f1753f2910ed9b79b4e`),
W3C's machine-readable extract of the IDL in the WebGL 1.0, WebGL 2.0 and
WebGPU specifications (package license: MIT).

`../generate.mjs` turns them into `dom/types/dom/webgl.d.lua` and
`dom/types/dom/webgpu.d.lua`. To update: replace these files from a newer
`@webref/idl`, update the version and checksum above, and run
`node dom/webidl/generate.mjs`.
