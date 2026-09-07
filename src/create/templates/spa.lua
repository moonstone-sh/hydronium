local spa = {}

function spa.files(opts)
  local project_name = opts.name or "my-hydronium-spa"
  local files = {}

  files["moonstone.toml"] = string.format([[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "bin"
description = "Client-side SPA powered by Hydronium"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies]
hydronium = { path = "../hydronium" }

[scripts]
dev = "hydronium dev"
build = "hydronium build"
]], project_name)

  files["index.html"] = string.format([[<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>%s</title>
</head>
<body>
  <div id="app"></div>
  <script type="module" src="/src/main.luax"></script>
</body>
</html>
]], project_name)

  files["src/main.luax"] = [[local h = require("hydronium")

local function App()
  local count, setCount = h.signal(0)

  return (
    <div style="font-family: sans-serif; text-align: center; padding: 2rem;">
      <h1>Hydronium SPA</h1>
      <p>Count: {count()}</p>
      <button onclick={() => setCount(count() + 1)}>Increment</button>
    </div>
  )
end

h.mount(App, "#app")
]]

  return files
end

return spa
