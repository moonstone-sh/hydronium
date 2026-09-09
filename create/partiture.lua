local ballad = require("ballad")

return ballad.partiture(function(p)
	local moonstone = p:use(ballad.plugins.moonstone)
	local project = moonstone.project({ root = "." })

	local layout = p:use(ballad.plugins.layout)
	local app = layout.exec(project, {
		name = "hydronium-create",
		bin = "hydronium-create",
		entry = "src/main.lua",
		interpreter = "luajit",
		include = { "src/**" },
	})

	local source_artifact = moonstone.registry.package(app, {
		name = project.registry_name or "hydronium/create",
		readme = "README.md",
		version = project.version,
		target = "any",
		runtime = project.runtime_spec or "moonstone/luajit@2.1",
		lua_abi = project.lua_abi or "5.1",
	})

	p.sink.artifact(source_artifact, {
		out = "dist/registry/create",
		product = "package",
	})
end)
