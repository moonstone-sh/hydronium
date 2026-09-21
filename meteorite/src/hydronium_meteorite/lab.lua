local discovery = require("hydronium_lab").discovery
local ink_lab = require("hydronium_ink_lab")

local M = {}
local state = { config = nil, registry = nil, service = nil, fingerprint = nil, generation = 0, error = nil, request_id = nil,
  instance = tostring({}) }

local function read(path)
  local file, err = io.open(path, "rb")
  if not file then error("cannot read " .. path .. ": " .. tostring(err), 0) end
  local value = file:read("*a") or ""
  file:close()
  return value
end

local function fingerprint(paths)
  local a, b = 5381, 0
  for _, path in ipairs(paths) do
    local source = read(path)
    for index = 1, #source do
      local byte = source:byte(index)
      a, b = (a * 33 + byte) % 4294967296, (b * 65599 + byte) % 4294967296
    end
    a = (a * 33 + #path) % 4294967296
  end
  return string.format("%08x%08x", a, b)
end

local function load_config()
  if state.config then return state.config end
  local chunk, err = loadfile(".hydronium/lab/config.lua")
  if not chunk then error("Hydronium Lab config is unavailable: " .. tostring(err), 0) end
  local config = chunk()
  if type(config) ~= "table" or type(config.paths) ~= "table" then error("Hydronium Lab config needs a paths list", 0) end
  state.config = config
  return config
end

-- A story is commonly a `.stories.luax` module which imports ordinary
-- sibling components written in `.luax`. Lua's stock searchers only inspect
-- `package.path`'s `.lua` candidates, so install one project-scoped LUAX
-- searcher before loading a story. It deliberately derives candidates from
-- the existing package path: the host, not Lab, remains the authority for
-- which project roots are importable.
local function install_luax_searcher()
  if package._hydronium_luax_searcher then return end
  local searchers = package.searchers or package.loaders
  if not searchers then return end
  table.insert(searchers, 2, function(module_name)
    local mapped = module_name:gsub("%.", "/")
    for template in package.path:gmatch("[^;]+") do
      local lua_path = template:gsub("%?", mapped)
      local luax_path = lua_path:gsub("%.lua$", ".luax")
      if luax_path ~= lua_path then
        local file = io.open(luax_path, "rb")
        if file then
          file:close()
          return function()
            return require("hydronium_luax.loader").load(luax_path, { module_id = module_name })
          end
        end
      end
    end
    return "\n\tno project LUAX module '" .. module_name .. "'"
  end)
  package._hydronium_luax_searcher = true
end

local function load_story(record)
  if record.transform == "luax" then
    _G.H = require("hydronium")
    _G.__luax = require("hydronium_luax.runtime")
    install_luax_searcher()
    return require("hydronium_luax.loader").load(record.path, { module_id = record.id_prefix:gsub("/", ".") })
  end
  local chunk, err = loadfile(record.path)
  if not chunk then error(err, 0) end
  return chunk()
end

local function rebuild(config, revision)
  local records = discovery.plan(config.paths, { roots = config.roots or { "src" } })
  local registry = discovery.registry(records, load_story)
  state.generation = state.generation + 1
  if state.service then state.service:invalidate(tostring(state.generation), registry) end
  state.registry, state.fingerprint, state.error = registry, revision, nil
  return registry
end

local function refresh()
  local config = load_config()
  local ok_fp, revision = pcall(fingerprint, config.paths)
  if not ok_fp then state.error = tostring(revision); return nil, state.error end
  if state.registry and state.fingerprint == revision then return state.registry end
  local ok, registry = pcall(rebuild, config, revision)
  if not ok then state.error = tostring(registry); return state.registry, state.error end
  return registry
end

local function service(c)
  local registry, err = refresh()
  if not registry then return nil, err end
  if not state.service then
    state.request_id = c:request_id()
    state.service = ink_lab.service.new(registry, {
      generation = tostring(state.generation),
      id = function()
        local value = tostring(state.request_id or "")
        state.request_id = nil
        return value .. value
      end,
    })
  end
  return state.service, err
end

local function same_origin(c)
  local origin, host = c:header("origin"), c:header("host")
  if not origin or origin == "" then return true end
  if not host or host == "" then return false end
  return origin == "http://" .. host or origin == "https://" .. host
end

local function mutation_allowed(c)
  return same_origin(c) and c:header("x-hydronium-lab") == "1"
end

function M.page(c)
  if not same_origin(c) then return c:text(403, "forbidden") end
  local config = load_config()
  local h = require("hydronium").h
  local Document = require("hydronium_ink_lab.dom")
  local body = require("hydronium_dom.server").render_to_string(h(Document, {
    title = config.title or "Hydronium Ink Lab",
    project_name = config.project_name or config.title or "Hydronium Ink Lab",
    project_id = config.project_id or config.project_name or "hydronium-lab",
  }), { doctype = true })
  return c:bytes(200, "text/html; charset=utf-8", body, { headers = { ["Cache-Control"] = "no-store", ["X-Content-Type-Options"] = "nosniff",
    ["Referrer-Policy"] = "no-referrer", ["Content-Security-Policy"] = "default-src 'self'; style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; script-src 'self'; connect-src 'self'" } })
end

local function package_client_path(name)
  local function search_module(module_name)
    if package.searchpath then return package.searchpath(module_name, package.path) end
    local mapped = module_name:gsub("%.", "/")
    for template in package.path:gmatch("[^;]+") do
      local candidate = template:gsub("%?", mapped)
      local file = io.open(candidate, "rb")
      if file then file:close(); return candidate end
    end
  end
  -- Resolve through Lua's package path instead of assuming this module lives
  -- under `<package>/src`. A Moonstone project exposes path/link packages as
  -- symlinked Lua modules under `.moonstone/env/share/lua/...`; both layouts
  -- have `hydronium_meteorite/lab.lua`, but only the source checkout has the
  -- old `/src/` ancestor.
  local module_path = search_module("hydronium_meteorite.lab")
  local module_root = module_path and module_path:match("^(.*)/hydronium_meteorite/lab%.lua$")
  if not module_root then error("cannot locate hydronium/meteorite package assets", 0) end
  if name == "meteorite.js" then
    return module_root .. "/hydronium_meteorite/client/meteorite.js", "text/javascript; charset=utf-8"
  end
  local ink_root = search_module("hydronium_ink_lab")
  if name == "virtual_terminal.js" and ink_root then
    return ink_root:gsub("/init%.lua$", "/client/virtual_terminal.js"), "text/javascript; charset=utf-8"
  end
  if name == "lab.css" and ink_root then return ink_root:gsub("/init%.lua$", "/client/lab.css"), "text/css; charset=utf-8" end
  return nil
end

function M.asset(c, name)
  if not same_origin(c) then return c:text(403, "forbidden") end
  local path, content_type = package_client_path(name)
  if not path then return c:text(404, "not found") end
  local ok, content = pcall(read, path)
  if not ok then return c:text(500, content) end
  return c:bytes(200, content_type, content, { headers = { ["Cache-Control"] = "no-cache", ["X-Content-Type-Options"] = "nosniff" } })
end

function M.catalog(c)
  if not same_origin(c) then return c:text(403, "forbidden") end
  local current, err = refresh()
  if not current then return c:json(500, { ok = false, outcome = "compile_error", message = err }) end
  return c:json({ ok = true, catalog = { version = 1, stories = current.manifest() }, generation = tostring(state.generation),
    instance = state.instance, error = err })
end

function M.create_session(c)
  if not mutation_allowed(c) then return c:text(403, "forbidden") end
  state.request_id = c:request_id()
  local current, err = service(c)
  if not current then return c:json(500, { ok = false, outcome = "compile_error", message = err }) end
  return c:json(current:create())
end

function M.operation(c)
  if not mutation_allowed(c) then return c:text(403, "forbidden") end
  local body, decode_err = c:json_body()
  if not body then return c:json(400, { ok = false, outcome = "invalid_request", message = decode_err }) end
  local current, compile_err = service(c)
  if not current then return c:json(500, { ok = false, outcome = "compile_error", message = compile_err }) end
  if compile_err then return c:json(409, { ok = false, outcome = "compile_error", message = compile_err }) end
  return c:json(current:operate(c:param("id"), body, #(c:body() or "")))
end

function M.close_session(c)
  if not mutation_allowed(c) then return c:text(403, "forbidden") end
  local current = service(c)
  if not current then return c:json({ ok = true, outcome = "closed", existed = false }) end
  return c:json(current:close(c:param("id")))
end

function M.reset_for_test()
  if state.service then state.service:shutdown() end
  state = { config = nil, registry = nil, service = nil, fingerprint = nil, generation = 0, error = nil, request_id = nil,
    instance = tostring({}) }
end

return M
