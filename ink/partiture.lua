local ballad = require("ballad")

return ballad.partiture(function(p)
    local moonstone = p:use(ballad.plugins.moonstone)
    local convention = ballad.conventions
    local project = moonstone.project({ root = "." })
    local artifact = moonstone.registry.source_package(project, {
        readme = "REGISTRY_README.md",
        include_add = {
            "native/dist/aarch64-linux-gnu/**",
            "native/dist/aarch64-macos/**",
            "native/dist/x86_64-linux-gnu/**",
            "native/dist/x86_64-macos/**",
            "native/select-yoga.sh",
        },
        materialize = convention.command({
            command = "sh",
            args = { "native/select-yoga.sh" },
        }),
        collect = {
            lua_modules = {
                convention.tree("src", {
                    prefix = "hydronium_ink",
                    strip_prefix = "hydronium_ink/",
                }),
            },
            native_lib = {
                convention.file("libyogacore.dylib", "native/selected/libyogacore.dylib"),
                convention.file("libyogacore.so", "native/selected/libyogacore.so"),
            },
        },
    })
    p.sink.artifact(artifact, { out = "dist/registry", product = "package" })
end)
