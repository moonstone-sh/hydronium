local ballad = require("ballad")
return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local convention = ballad.conventions
  local project = moonstone.project({ root = "." })
  local artifact = moonstone.registry.source_package(project, {
    readme = "README.md",
    include_add = { "compiler/**" },
    collect = {
      lua_modules = { convention.tree("src", { prefix = "hydronium_i18n", strip_prefix = "hydronium_i18n/" }) },
      assets = { convention.tree("compiler", { prefix = "compiler" }) },
    },
  })
  p.sink.artifact(artifact, { out = "dist/registry", product = "package" })
end)
