--[[
  Meteorite + Hydronium SSR Main Entrypoint
  Loads .luax components, compiles them to Lua source, and registers them
  as first-class HTTP route handlers on the Meteorite application graph.
--]]

-- Ensure package paths for Hydronium and Meteorite
local function setup_paths()
  local roots = {
    "src/?.lua;src/?/init.lua;",
    "../hydronium/src/?.lua;../hydronium/src/?/init.lua;",
    "../meteorite/src/?.lua;../meteorite/src/?/init.lua;",
    "meteorite/src/?.lua;meteorite/src/?/init.lua;",
  }
  package.path = table.concat(roots, "") .. package.path
end
setup_paths()

local hydronium = require("hydronium")
local h = hydronium.createElement
local luax = require("hydronium.luax")
local meteorite_adapter = require("hydronium.server.meteorite")
local meteorite = require("meteorite")

-- Helper to load and compile a .luax component file
local function load_luax(filepath)
  local f = io.open(filepath, "r")
  if not f then
    -- Try relative to hydronium root
    f = io.open("../hydronium/" .. filepath, "r")
  end
  if not f then
    error("Cannot open .luax file: " .. tostring(filepath))
  end
  local source = f:read("*a")
  f:close()

  local compiled = luax.compile(source, {
    filename = filepath,
    runtime = "hydronium",
    development = false,
  })

  local load_fn = loadstring or load
  local chunk, err = load_fn(compiled.code, "@" .. filepath)
  if not chunk then
    error("Syntax error loading compiled .luax [" .. filepath .. "]: " .. tostring(err))
  end
  return chunk()
end

-- Compile .luax view component
local AppView = load_luax("examples/meteorite_ssr/views/App.luax")

-- Create real Meteorite app instance
local app = meteorite.app({
  name = "meteorite-hydronium-app",
  host = "127.0.0.1",
  port = 8080,
})

-- 1. Root SSR Route rendering AppView (.luax component)
app:get("/", meteorite_adapter.handler(AppView, {
  status = 200,
  props = { title = "Home | Hydronium .luax SSR", path = "/" },
}))

-- 2. Package View Route with dynamic params and query
app:get("/packages/:name", function(c)
  local name = c.params and c.params.name or "unknown"
  local version = (type(c.query) == "function" and c:query("v")) or (type(c.query) == "table" and c.query.v) or "latest"

  local PackageDetails = function()
    return h("div", { class = "card" }, {
      h("h2", nil, "Package: " .. name),
      h("p", nil, {
        h("span", { class = "badge" }, "Version: " .. version),
      }),
      h("pre", nil, {
        h("code", nil, "moon add " .. name .. "@" .. version),
      }),
    })
  end

  return meteorite_adapter.render(c, h(AppView, {
    title = "Package: " .. name .. " | Meteorite SSR",
    path = "/packages/" .. name,
  }, {
    h(PackageDetails),
  }))
end)

-- 3. ErrorBoundary Test Route
app:get("/error-test", function(c)
  local ThrowingComponent = function()
    error("Simulated database failure during SSR!")
  end

  local Fallback = function(err)
    return h("div", { class = "card" }, {
      h("h2", { style = { color = "#ef4444" } }, "Caught by Hydronium ErrorBoundary"),
      h("p", nil, "Hydronium safely caught a server component error without crashing Meteorite:"),
      h("pre", nil, {
        h("code", nil, tostring(err.message or err)),
      }),
    })
  end

  local Page = function()
    return h(AppView, {
      title = "ErrorBoundary Test | Meteorite SSR",
      path = "/error-test",
    }, {
      h(hydronium.ErrorBoundary, { fallback = Fallback }, {
        h(ThrowingComponent),
      }),
    })
  end

  return meteorite_adapter.render(c, h(Page), { status = 500 })
end)

-- 4. Pure JSON Health Route (demonstrating coexistence of JSON and HTML routes)
app:get("/api/health", function(c)
  return c:json({
    status = "ok",
    framework = "meteorite",
    renderer = "hydronium.server",
    timestamp = os.time(),
  })
end)

return app
