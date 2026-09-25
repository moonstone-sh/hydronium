local ballad = require("ballad")

return ballad.partiture(function(p)
	local moonstone = p:use(ballad.plugins.moonstone)
	local project = moonstone.project({ root = "." })

	local layout = p:use(ballad.plugins.layout)
	local app = layout.exec(project, {
		name = "hydronium-cli",
		bin = "hydronium",
		entry = "src/main.lua",
		interpreter = "luajit",
		-- Stories belong to the optional Lab workbench. Keep the console's
		-- runtime UI, but do not ship its Lab catalog entry in this executable.
		include = {
			"src/build_runner.lua",
			"src/build_verify.lua",
			"src/dev_log.lua",
			"src/dev_supervisor.lua",
			"src/event_model.lua",
			"src/inspector.lua",
			"src/main.lua",
			"src/query.lua",
			"src/ui/app.lua",
			"src/ui/build_view.lua",
			"src/ui/inspector_view.lua",
			"src/ui/search_bar.lua",
			"src/ui/search_field.lua",
		},
	})

	local source_artifact = moonstone.registry.package(app, {
		name = project.registry_name or "hydronium/cli",
		readme = "README.md",
		version = project.version,
		target = "any",
		runtime = project.runtime_spec or "moonstone/luajit@2.1",
		lua_abi = project.lua_abi or "5.1",
	})

	p.sink.artifact(source_artifact, {
		out = "dist/registry/cli",
		product = "package",
	})
end)
