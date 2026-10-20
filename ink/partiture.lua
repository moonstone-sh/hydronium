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
            "native/dist/x86_64-windows-gnu/*.dll",
        },
        collect = {
            lua_modules = {
                convention.tree("src", {
                    prefix = "hydronium_ink",
                    strip_prefix = "hydronium_ink/",
                }),
            },
            -- Copy-only materialization works without sh/cp/uname. Keep
            -- foreign libraries out of the host loader search path; Ink picks
            -- its own target's library from the explicit package root.
            assets = {
                convention.tree("native/dist", { prefix = "native", include = { "**/*.dll", "**/*.so", "**/*.dylib" } }),
            },
        },
    })
    p.sink.artifact(artifact, { out = "dist/registry", product = "package" })
end)
