local love = {}

function love.files(opts)
  local project_name = opts.name or "my-hydronium-love-app"
  local files = {}

  files["moonstone.toml"] = string.format([=[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "script"
description = "LÖVE game with topology-backed Hydronium HMR"

[interpreter]
name = "luajit"
version = "2.1.0"
abi = "5.1"

[scripts]
run = "love ."
package = "moon exec -- ballad play partiture.lua"

[[dependencies]]
name = "hydronium/core"
constraint = "^0.1.0"
role = "runtime"

[[dependencies]]
name = "moonstone/ballad"
constraint = "^0.3.7"
role = "tool"
]=], project_name)

  files[".gitignore"] = [[.moonstone/
*.log
]]

  files["hydronium.sources.lua"] = [[return {
  roots = {
    { path = "src", namespace = "game", target = "client", update = "remount", effects = "safe",
      transforms = { lua = "lua" } },
  },
  entries = {
    { id = "game", path = "src/App.lua" },
  },
}
]]

  files["src/App.lua"] = [[local App = {}

function App.update(dt)
  App.time = (App.time or 0) + dt
end

function App.draw(graphics)
  graphics.clear(0.05, 0.07, 0.12)
  graphics.setColor(0.4, 0.85, 1)
  graphics.print("Hydronium + LÖVE", 32, 32)
  graphics.setColor(1, 1, 1)
  graphics.print("Edit src/App.lua to remount this game module.", 32, 62)
  graphics.print(string.format("Time: %.1f", App.time or 0), 32, 92)
end

return App
]]

  files["main.lua"] = [[local hmr = require("hydronium.core.hmr")
local graph = require("hydronium.core.module_graph")
local topology = require("hydronium.core.source_topology")
local love_hmr = require("hydronium.core.love_hmr")

local config = assert(loadfile("hydronium.sources.lua"))()
local records = topology.resolve(config, { "src/App.lua" })
local app_id = "game"
local source = assert(love.filesystem.read("src/App.lua"))
hmr.install(app_id, source)
graph.manage(app_id, { effects = "safe" })
local app = require(app_id)

-- `update()` is the explicit frame-safe boundary. This example uses a
-- remount boundary, so it safely replaces the module while making no promise
-- to retain arbitrary game state across an edit.
local updates = love_hmr.from_love({
  records = records,
  root = "love-root",
  on_remount = function()
    app = require(app_id)
  end,
  on_restart = function(result)
    print("Hydronium LÖVE: restart required: " .. tostring(result.reason))
  end,
})
assert(updates:prime())

function love.update(dt)
  local result = updates:update()
  if result and result.outcome == "rejected" then
    print("Hydronium LÖVE: update rejected: " .. tostring(result.reason))
  end
  if app.update then app.update(dt) end
end

function love.draw()
  app.draw(love.graphics)
end
]]

  files["partiture.lua"] = love.addon_files()["hydronium.love.partiture.lua"]

  files["README.md"] = string.format([[# %s

A small LÖVE game wired to Hydronium's topology-backed HMR host.

## Run

Install [LÖVE 11.5](https://love2d.org/) for the target platform. Moonstone
provisions the matching LuaJIT 5.1 dependency environment:

```bash
moon sync
moon run run
```

Build a deterministic, dependency-closed archive with `moon run package`.
The result is `dist/game.love` and does not read `.moonstone/env` at runtime.

Edit `src/App.lua`. The update is staged at the `love.update` frame boundary
and applied through a controlled module remount. State retention is deliberately
not assumed for game modules; mark modules `effects = "safe"` only when their
evaluation has no untracked external effects.
]], project_name)

  return files
end

--- Files safe to layer into an existing LÖVE project. They never replace the
--- game's main.lua or manifest: package installation remains `moon add`, and
--- the game author chooses the explicit remount boundary.
function love.addon_files()
  return {
    ["src/hydronium_love.lua"] = [[-- Add this module to an existing LÖVE game; it owns no game state.
local hmr = require("hydronium.core.hmr")
local graph = require("hydronium.core.module_graph")
local topology = require("hydronium.core.source_topology")
local love_hmr = require("hydronium.core.love_hmr")

local M = {}

--- Install a declared game module and return its current export plus an
--- adapter. Call adapter:update() from love.update().
function M.watch(opts)
  assert(type(opts) == "table" and type(opts.module_id) == "string", "module_id is required")
  assert(type(opts.path) == "string", "path is required")
  local record = {
    id = opts.module_id, path = opts.path, target = "client",
    transform = "lua", update = "remount", effects = opts.effects or "safe",
  }
  local source = assert(love.filesystem.read(record.path))
  hmr.install(record.id, source)
  graph.manage(record.id, { effects = record.effects })
  local current = require(record.id)
  local adapter = love_hmr.from_love({
    records = { record }, root = opts.root or "love-root",
    on_remount = function() current = require(record.id) end,
    on_restart = opts.on_restart,
  })
  assert(adapter:prime())
  return function() return current end, adapter
end

M.resolve = topology.resolve
return M
]],
    ["hydronium.love.partiture.lua"] = [[local ballad = require("ballad")

return ballad.partiture(function(p)
  local moonstone = p:use(ballad.plugins.moonstone)
  local love = p:use(ballad.plugins.love)
  local project = moonstone.project({ root = "." })
  local app = love.layout(project, {
    main = "main.lua",
    -- Keep the project shape open: src/, lib/, scenes/, assets/, and feature
    -- directories are all included. Only development metadata is excluded.
    exclude = {
      ".moonstone/**", ".ballad/**", "dist/**", ".git/**",
      "moonstone.toml", "moonstone.lock", ".luarc.json",
      "HYDRONIUM_LOVE.md", "hydronium.love.partiture.lua", "partiture.lua",
    },
  })
  local archive = love.pack(app, { out = "dist/game.love", deterministic = true })
  p.sink.directory(app, { out = "dist/love-root", file_graph = true })
  p.sink.artifact(archive, { out = "dist/game.love" })
end)
]],
    ["HYDRONIUM_LOVE.md"] = [[# Add Hydronium HMR to this LÖVE project

`hydronium-create --add-love` configured a LÖVE-compatible LuaJIT 5.1
environment, added Hydronium and Ballad through the Moonstone CLI, synchronized
the lockfile, and installed two dedicated scripts. Install
[LÖVE 11.5](https://love2d.org/) for the target platform if `love` is not
already on `PATH`:

```bash
moon run love-dev
moon run love-package
```

`love-dev` launches the host's LÖVE executable with Moonstone's dependency
paths. The package command writes `dist/game.love`; Ballad copies the Lua dependency
closure into the archive, so it does not depend on `.moonstone/env` at runtime.

`src/hydronium_love.lua` is an additive bridge. In `main.lua`, choose one
module that is safe to re-evaluate and an explicit frame boundary:

```lua
local current, updates = require("src.hydronium_love").watch({
  module_id = "game", path = "src/game.lua", effects = "safe",
  on_restart = function(result) print(result.reason) end,
})

function love.update(dt)
  updates:update() -- after game input/update, before love.draw
  current().update(dt)
end
```

Use `effects = "restart"` for modules that mutate globals, register external
callbacks, or perform I/O during evaluation. Hydronium will preserve the old
game and request a controlled restart instead of guessing.

The bridge never edits `main.lua`. This is intentional: only the game knows
which module owns disposable state and where its frame-safe update boundary is.
The generated Ballad file includes arbitrary project directories by default;
edit its `exclude` list if the game has additional development-only trees.
]],
  }
end

return love
