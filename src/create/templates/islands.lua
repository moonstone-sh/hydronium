local islands = {}

function islands.files(opts)
  local project_name = opts.name or "my-hydronium-islands"
  local files = {}

  files["moonstone.toml"] = string.format([[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "bin"
description = "Hydronium Islands architecture with SSR and Client-side Hydration"

[interpreter]
name = "lua"
version = "5.4"
abi = "5.4"

[dependencies]
hydronium = { path = "../hydronium" }

[scripts]
dev = "meteorite dev"
build = "meteorite build"
start = "meteorite start"
]], project_name)

  files[".luarc.json"] = [[{
  "$schema": "https://raw.githubusercontent.com/LuaLS/vscode-lua/master/setting/schema.json",
  "runtime.version": "Lua 5.4",
  "workspace.library": [
    ".moonstone/env/share/lua/5.4"
  ]
}]]

  files[".gitignore"] = [[.moonstone/
dist/
.zig-cache/
zig-out/
*.log
]]

  files["views/Counter.luax"] = [[-- Interactive Client Island
local h = require("hydronium")

local function Counter(props)
  local count, setCount = h.signal(props.initial or 0)

  return (
    <div class="island-box">
      <p class="island-badge">Client Island (Interactive)</p>
      <span class="count-val">Count: {count()}</span>
      <div class="btn-group">
        <button onclick={() => setCount(count() - 1)} class="btn btn-secondary">-</button>
        <button onclick={() => setCount(count() + 1)} class="btn btn-primary">+</button>
      </div>
    </div>
  )
end

return Counter
]]

  files["views/App.luax"] = string.format([[-- Server-Rendered Shell with Embedded Island
local h = require("hydronium")
local Counter = require("views.Counter")

local function App(props)
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>%s</title>
        <link rel="stylesheet" href="/public/style.css" />
      </head>
      <body>
        <div class="shell">
          <header>
            <h1>%s</h1>
            <p>Zero-JS Static Shell with Partial Hydration Islands</p>
          </header>

          <main>
            <section class="content">
              <h2>Static Content (0 KB Client JavaScript)</h2>
              <p>This section is rendered purely on the server without any client runtime overhead.</p>
            </section>

            <section class="island-container">
              <Counter initial={10} hydration="client" />
            </section>
          </main>
        </div>
      </body>
    </html>
  )
end

return App
]], project_name, project_name)

  files["src/main.lua"] = [[local meteorite = require("meteorite")
local hydronium = require("hydronium")
local App = require("views.App")

local app = meteorite.create()

app:use(meteorite.static("/public", "public"))

app:get("/", function(req, res)
  local html = hydronium.render_to_string(App, {})
  res:header("Content-Type", "text/html; charset=utf-8")
  return res:send(html)
end)

return app
]]

  files["public/style.css"] = [[body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  background: #0f172a;
  color: #f8fafc;
  padding: 2rem;
}
.shell {
  max-width: 600px;
  margin: 0 auto;
}
.island-box {
  background: #1e293b;
  border: 1px solid #38bdf8;
  border-radius: 8px;
  padding: 1.5rem;
  margin-top: 1.5rem;
  text-align: center;
}
.island-badge {
  color: #38bdf8;
  font-weight: bold;
  font-size: 0.85rem;
  margin-bottom: 0.5rem;
}
.count-val {
  font-size: 1.8rem;
  display: block;
  margin: 1rem 0;
}
.btn-group {
  display: flex;
  justify-content: center;
  gap: 0.5rem;
}
.btn {
  padding: 0.5rem 1.2rem;
  font-size: 1.2rem;
  border-radius: 6px;
  border: none;
  cursor: pointer;
}
.btn-primary { background: #38bdf8; color: #0f172a; }
.btn-secondary { background: #334155; color: #fff; }
]]

  return files
end

return islands
