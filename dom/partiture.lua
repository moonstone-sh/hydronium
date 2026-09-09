local ballad = require("ballad")

return ballad.partiture(function(p)
    local moonstone = p:use(ballad.plugins.moonstone)
    local convention = ballad.conventions
    local project = moonstone.project({ root = "." })
    local artifact = moonstone.registry.source_package(project, {
        readme = "REGISTRY_README.md",
        include_add = { "ambient-types/**", "types/**", "tools/**" },
        collect = {
            lua_modules = {
                convention.tree("src", {
                    prefix = "hydronium_dom",
                    strip_prefix = "hydronium_dom/",
                }),
            },
        },
    })
    p.sink.artifact(artifact, { out = "dist/registry", product = "package" })
end)
