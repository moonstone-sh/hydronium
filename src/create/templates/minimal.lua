local minimal = {}

function minimal.files(opts)
  local project_name = opts.name or "my-hydronium-app"
  local files = {}

  files["moonstone.toml"] = string.format([[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "script"
description = "Minimal Hydronium component"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies]
hydronium = { path = "../hydronium" }

[scripts]
run = "lua src/main.lua"
]], project_name)

  files["src/main.lua"] = [[local hydronium = require("hydronium")

local function Greeting(props)
  return (
    <div>
      <h1>Hello, {props.name or "World"}!</h1>
    </div>
  )
end

local html = hydronium.render_to_string(Greeting, { name = "Hydronium Developer" })
print("Rendered HTML:")
print(html)
]]

  return files
end

return minimal
