local ssr = {}

function ssr.files(opts)
  local project_name = opts.name or "my-hydronium-app"
  local interpreter = opts.interpreter or "lua@5.4"

  local files = {}

  files["moonstone.toml"] = string.format([[manifest_version = 2

[package]
name = "%s"
version = "0.1.0"
kind = "bin"
description = "Full-stack SSR application powered by Hydronium and Meteorite"

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

  files["views/App.luax"] = string.format([[-- Root View Component
local h = require("hydronium")

local function App(props)
  local count, setCount = h.signal(props.initial_count or 0)

  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>%s</title>
        <link rel="stylesheet" href="/public/style.css" />
      </head>
      <body>
        <main class="container">
          <header class="hero">
            <h1>Welcome to %s</h1>
            <p class="subtitle">Deterministic Reactive UI for Lua</p>
          </header>

          <section class="card">
            <h2>Reactive Signal Counter</h2>
            <div class="counter-box">
              <span class="count-display">Count: {count()}</span>
              <div class="button-group">
                <button onclick={() => setCount(count() - 1)} class="btn btn-secondary">-</button>
                <button onclick={() => setCount(count() + 1)} class="btn btn-primary">+</button>
              </div>
            </div>
          </section>

          <footer>
            <p>Powered by <strong>Hydronium</strong> & <strong>Meteorite</strong></p>
          </footer>
        </main>
      </body>
    </html>
  )
end

return App
]], project_name, project_name)

  files["src/main.lua"] = [[-- Server entrypoint
local meteorite = require("meteorite")
local hydronium = require("hydronium")
local App = require("views.App")

local app = meteorite.create()

app:use(meteorite.static("/public", "public"))

app:get("/", function(req, res)
  local initial_count = tonumber(req.query.count) or 0
  local html = hydronium.render_to_string(App, { initial_count = initial_count })
  res:header("Content-Type", "text/html; charset=utf-8")
  return res:send(html)
end)

app:get("/api/health", function(req, res)
  return res:json({ status = "ok", timestamp = os.time() })
end)

return app
]]

  files["public/style.css"] = [[* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  background: #0f172a;
  color: #f8fafc;
  display: flex;
  justify-content: center;
  align-items: center;
  min-height: 100vh;
}

.container {
  max-width: 640px;
  width: 100%;
  padding: 2rem;
}

.hero {
  text-align: center;
  margin-bottom: 2rem;
}

.hero h1 {
  font-size: 2.5rem;
  font-weight: 700;
  background: linear-gradient(135deg, #38bdf8, #818cf8);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  margin-bottom: 0.5rem;
}

.subtitle {
  color: #94a3b8;
  font-size: 1.1rem;
}

.card {
  background: #1e293b;
  border-radius: 12px;
  padding: 2rem;
  box-shadow: 0 10px 25px rgba(0, 0, 0, 0.3);
  border: 1px solid #334155;
  text-align: center;
  margin-bottom: 2rem;
}

.card h2 {
  font-size: 1.3rem;
  margin-bottom: 1.5rem;
  color: #e2e8f0;
}

.counter-box {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 1.25rem;
}

.count-display {
  font-size: 2rem;
  font-weight: 600;
  color: #38bdf8;
}

.button-group {
  display: flex;
  gap: 1rem;
}

.btn {
  padding: 0.6rem 1.5rem;
  font-size: 1.25rem;
  font-weight: bold;
  border-radius: 8px;
  border: none;
  cursor: pointer;
  transition: transform 0.1s ease, background-color 0.2s ease;
}

.btn:hover {
  transform: translateY(-2px);
}

.btn-primary {
  background: #38bdf8;
  color: #0f172a;
}

.btn-primary:hover {
  background: #7dd3fc;
}

.btn-secondary {
  background: #334155;
  color: #f8fafc;
}

.btn-secondary:hover {
  background: #475569;
}

footer {
  text-align: center;
  color: #64748b;
  font-size: 0.9rem;
}
]]

  files["README.md"] = string.format([[# %s

Full-stack SSR application built with [Hydronium](https://moonstone.sh/packages/hydronium) and [Meteorite](https://moonstone.sh/packages/meteorite).

## Getting Started

1. **Install Dependencies:**
   ```bash
   moon sync
   ```

2. **Start Dev Server (with HMR):**
   ```bash
   moon run dev
   ```

3. **Build for Production:**
   ```bash
   moon run build
   ```
]], project_name)

  return files
end

return ssr
