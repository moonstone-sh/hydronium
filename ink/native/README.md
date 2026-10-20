# hydronium-ink native build

Cross-compiles vendored Yoga (`vendor/yoga/`, see `vendor/yoga/VENDORED.md`
for the pinned tag) into `libyogacore` for five target triples using `zig
c++` directly — no CMake, verified safe because upstream's own
`yoga/CMakeLists.txt` is a dependency-free `file(GLOB *.cpp **/*.cpp)`.

```bash
cd ink/native
zig build                    # debug build, all 5 targets, into dist/<triple>/
zig build --release=safe     # what an actual publish should use
```

Output: `dist/<triple>/libyogacore.{dylib,so}` (macOS/Linux) or
`dist/<triple>/yogacore.dll` (Windows). Only the host's own target
(`aarch64-macos` on this machine) can actually be run and verified here;
the rest are cross-compiled and checked for successful compilation only.

Verified on this machine: all 5 targets compile cleanly. The native
`aarch64-macos` build exports the expected C symbols (checked with
`nm -gU dist/aarch64-macos/libyogacore.dylib`).

The registry package carries each prebuilt under `native/<target>/`. It uses
Moonstone's copy-only materializer, and the FFI loader chooses the matching
library from `MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK`. Foreign libraries are
assets, not entries in the host's dynamic-loader path. Native Windows CI
exports this package, installs it from a disposable file registry, loads Yoga,
and exercises an allocated console; cross-compilation alone is not that proof.
