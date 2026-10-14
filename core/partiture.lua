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
        include_add = { "types/**" },
        collect = {
            assets = {
                convention.tree("types", { prefix = "types" }),
            },
            lua_modules = {
                convention.tree("src", {
                    prefix = "hydronium",
                    strip_prefix = "hydronium/",
                    exclude = FLAVOR_VARIANTS_IN_TREE,
                }),
            },
        },
    })
    p.sink.artifact(artifact, { out = "dist/registry", product = "package" })
end)
