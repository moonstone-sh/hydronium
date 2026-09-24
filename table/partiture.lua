local ballad = require("ballad")
return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local project = moonstone.project({ root = "." })
  local artifact = moonstone.registry.source_package(project, {
    readme = "REGISTRY_README.md",
    include_add = { "types/**" },
    collect = {
      assets = { ballad.conventions.tree("types", { prefix = "types" }) },
      lua_modules = { ballad.conventions.tree("src", {
        prefix = "hydronium_table", strip_prefix = "hydronium_table/",
      }) },
    },
  })
  p.sink.artifact(artifact, { out = "dist/registry", product = "package" })
end)
