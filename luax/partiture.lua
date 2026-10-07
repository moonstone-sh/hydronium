local ballad = require("ballad")

return ballad.partiture(function(p)
    local moonstone = p:use(ballad.plugins.moonstone)
    local convention = ballad.conventions
    local project = moonstone.project({ root = "." })
    local artifact = moonstone.registry.source_package(project, {
        readme = "REGISTRY_README.md",
        include_add = {
            ".luarc.json",
            ".vscodeignore",
            "ftdetect/**",
            "nvim/**",
            "parser/**",
            "queries/**",
            "syntaxes/**",
            "tools/**",
            "tree-sitter-luax/**",
            "types/**",
            "language-configuration.json",
            "editor/luax-tags.mjs",
            "editor/dom-data.json",
            "editor/build-dom-data.mjs",
            "editor/luals-web/*.lua",
            "editor/luals-web/*.c",
            "editor/luals-web/*.mjs",
            "editor/luals-web/*.sh",
            "editor/luals-web/README.md",
            "package.json",
        },
        collect = {
            assets = {
                convention.tree("types", { prefix = "types" }),
                convention.tree("syntaxes", { prefix = "syntaxes" }),
            },
            lua_modules = {
                convention.tree("src", {
                    prefix = "hydronium_luax",
                    strip_prefix = "hydronium_luax/",
                }),
            },
        },
    })
    p.sink.artifact(artifact, { out = "dist/registry", product = "package" })
end)
