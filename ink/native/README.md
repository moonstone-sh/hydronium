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
