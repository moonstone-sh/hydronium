local ballad = require("ballad")

-- Moonstone flavor variants (`compat@lua54.lua`) stay out of the published
-- artifact for now: Moonstone's canonical artifact paths allow only
-- [A-Za-z0-9._-] (src/core/archive/canonical_artifact.zig), so `moon
-- artifact create` rejects `@`. The untagged fallbacks work everywhere.
-- Drop these excludes once Moonstone accepts variant file names.
local FLAVOR_VARIANTS = { "src/**/*@*" }
local FLAVOR_VARIANTS_IN_TREE = { "**/*@*" }

return ballad.partiture(function(p)
    local moonstone = p:use(ballad.plugins.moonstone)
    local convention = ballad.conventions
    local project = moonstone.project({ root = "." })
    local artifact = moonstone.registry.source_package(project, {
        readme = "REGISTRY_README.md",
        exclude = FLAVOR_VARIANTS,
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
                    exclude = FLAVOR_VARIANTS_IN_TREE,
                }),
            },
        },
    })
    p.sink.artifact(artifact, { out = "dist/registry", product = "package" })
end)
