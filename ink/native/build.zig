// Cross-compiles vendored facebook/yoga (see vendor/yoga/VENDORED.md for the
// pinned tag/commit) into a shared library per target triple, using `zig
// c++` directly instead of Yoga's own CMake build -- verified viable because
// upstream `yoga/CMakeLists.txt` is `file(GLOB *.cpp **/*.cpp)` with zero
// third-party dependencies (only conditionally links Android's `log`), so
// there is no dependency graph CMake would otherwise resolve for us.
//
// `Yoga.h` is a plain C API (see YGMacros.h's YG_EXTERN_C_BEGIN/YG_EXPORT):
// the shared library's external ABI is C function signatures only, which is
// what makes it safe to consume from LuaJIT's FFI regardless of which C++
// runtime (libc++/libstdc++) or ABI (MinGW/MSVC) this was built with -- none
// of that ever needs to match the consumer, since no C++ symbol crosses the
// boundary.
//
// Usage: `zig build` from this directory (ink/native/) builds every target
// listed below into dist/<triple>/libyogacore.<ext>. Only the host's own
// target can actually be *run*; the rest are cross-compiled and verified by
// successful compilation only (same limitation this workspace's own
// moonstone project documents for its Windows target -- see
// moonstone/docs/maintenance/native-library-projection-contract-2026-08-09.md's
// "Windows Certification Boundary").

const std = @import("std");

// Hardcoded rather than walked at build-config time: vendor/yoga's .cpp
// list is small (19 files) and changes only when VENDORED.md's pinned tag
// is bumped, and Zig's directory-walking API (std.Io.Dir in this Zig
// version) has been a moving target across releases -- a fixed list here
// is more stable than chasing that API across Zig upgrades.
const yoga_sources = [_][]const u8{
    "yoga/algorithm/AbsoluteLayout.cpp",
    "yoga/algorithm/Baseline.cpp",
    "yoga/algorithm/Cache.cpp",
    "yoga/algorithm/CalculateLayout.cpp",
    "yoga/algorithm/FlexLine.cpp",
    "yoga/algorithm/PixelGrid.cpp",
    "yoga/config/Config.cpp",
    "yoga/debug/AssertFatal.cpp",
    "yoga/debug/Log.cpp",
    "yoga/event/event.cpp",
    "yoga/node/LayoutResults.cpp",
    "yoga/node/Node.cpp",
    "yoga/YGConfig.cpp",
    "yoga/YGEnums.cpp",
    "yoga/YGNode.cpp",
    "yoga/YGNodeLayout.cpp",
    "yoga/YGNodeStyle.cpp",
    "yoga/YGPixelGrid.cpp",
    "yoga/YGValue.cpp",
};

const Triple = struct {
    /// Also the artifact directory name under dist/ -- kept as the plain
    /// "<arch>-<os>[-<abi>]" form the rest of this workspace's own
    /// moonstone target vocabulary uses (see
    /// moonstone/docs/maintenance/native-library-projection-contract-2026-08-09.md),
    /// not Zig's own `zigTriple()` spelling, so the moonstone packaging
    /// step in Phase B/E can key artifacts by this name directly.
    dist_name: []const u8,
    query: std.Target.Query,
};

const triples = [_]Triple{
    .{ .dist_name = "aarch64-macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .dist_name = "x86_64-macos", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
    .{ .dist_name = "x86_64-linux-gnu", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu } },
    .{ .dist_name = "aarch64-linux-gnu", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu } },
    .{ .dist_name = "x86_64-windows-gnu", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } },
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    for (triples) |triple| {
        const target = b.resolveTargetQuery(triple.query);
        const is_windows = triple.query.os_tag == .windows;

        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        });
        mod.addIncludePath(b.path("vendor"));

        var flags = std.array_list.Managed([]const u8).init(b.allocator);
        flags.append("-std=c++20") catch @panic("OOM");
        // Windows only auto-exports symbols marked __declspec(dllexport);
        // YGMacros.h's YG_EXPORT only expands to that when _WINDLL is
        // defined (see vendor/yoga/YGMacros.h) -- ELF/Mach-O export
        // everything with default visibility regardless, so this define is
        // a no-op there but required here for the DLL to expose anything.
        if (is_windows) flags.append("-D_WINDLL") catch @panic("OOM");

        mod.addCSourceFiles(.{
            .root = b.path("vendor"),
            .files = &yoga_sources,
            .flags = flags.items,
        });

        const lib = b.addLibrary(.{
            .name = "yogacore",
            .linkage = .dynamic,
            .root_module = mod,
        });

        const install = b.addInstallArtifact(lib, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("../dist/{s}", .{triple.dist_name}) } },
        });
        b.getInstallStep().dependOn(&install.step);
    }
}
