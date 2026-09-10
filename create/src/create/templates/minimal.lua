local minimal = {}

function minimal.files(opts)
  local project_name = opts.name or "my-hydronium-app"
  local files = {}

  files["moonstone.toml"] = string.format([=[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "script"
description = "Minimal Hydronium component"

[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"

[scripts]
run = "lua src/main.lua"

[[dependencies]]
name = "moonstone/hydronium"
constraint = "path:../hydronium/core"
role = "runtime"

[[dependencies]]
name = "moonstone/hydronium-dom"
constraint = "path:../hydronium/dom"
role = "runtime"
]=], project_name)

  files[".gitignore"] = [[.moonstone/
*.log
]]

  -- Plain Lua, no `.luax`/JSX -- deliberately: "minimal" means no
  -- compile step at all, just `lua src/main.lua`. `h.h(tag, props, ...)`
  -- is the same element factory `.luax` compiles JSX into; writing it
  -- directly here is not a workaround, it's the same primitive.
  --
  files["src/main.lua"] = [[local h = require("hydronium")
local server = require("hydronium_dom.server")

local function Greeting(props)
  return h.h("div", nil,
    h.h("h1", nil, "Hello, " .. (props.name or "World") .. "!")
  )
end

local html = server.render_to_string(h.h(Greeting, { name = "Hydronium Developer" }))
print("Rendered HTML:")
print(html)
]]

  files["README.md"] = string.format([[# %s

Minimal Hydronium component -- no compiler or client runtime. It imports the
core package plus `hydronium_dom.server` for server rendering.

## Getting Started

```bash
moon sync
moon run run
```

The core runtime is declared as a Moonstone path dependency. During local
development this template assumes your project sits next to a `hydronium`
clone, e.g.:

```
some-parent-dir/
  hydronium/
  %s/   <- this project
```
]], project_name, project_name)

  return files
end

return minimal
