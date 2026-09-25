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
		-- The Ink Lab story and its presentation helpers live alongside the
		-- generator for local development, but are intentionally absent from
		-- the released create executable. Lab is an opt-in workbench, not a
		-- production dependency of `hydronium-create`.
		include = {
			"src/main.lua",
			"src/create/init.lua",
			"src/create/luals.lua",
			"src/create/pm.lua",
			"src/create/process.lua",
			"src/create/router_mode.lua",
			"src/create/tailwind.lua",
			"src/create/wizard.lua",
			"src/create/writer.lua",
			"src/create/templates/**",
		},
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
