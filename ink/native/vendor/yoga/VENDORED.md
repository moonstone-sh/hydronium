# Vendored: facebook/yoga

- Upstream: https://github.com/facebook/yoga
- Pinned tag: `v3.2.1`
- Pinned commit: `042f5013152eb81c1552dec945b88f7b95ca350f`
- Vendored subtree: `yoga/` only (the core C++ library — no `tests/`, no
  `fuzz/`, no `CMakeLists.txt`). Verified via upstream's own
  `yoga/CMakeLists.txt` that this subtree has zero third-party
  dependencies (`file(GLOB *.cpp **/*.cpp)`, only conditionally links
  Android's `log`) — pure C++20 stdlib, which is what makes compiling it
  directly with `zig c++` (see `../build.zig`) viable without pulling in
  CMake or any of Yoga's own build tooling.
- License: MIT (`LICENSE` in this directory, copied from upstream root).
- The public C API this binding targets is `Yoga.h` in this directory —
  a plain C surface; the C++ internals behind it are never touched
  directly from Lua.

To re-vendor at a newer tag: re-clone upstream at the new tag, replace the
contents of this directory (except this file) with its `yoga/` subtree
(dropping `CMakeLists.txt`/`module.modulemap`), and update the pinned
tag/commit above.
