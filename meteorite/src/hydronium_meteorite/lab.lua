local discovery = require("hydronium_lab").discovery
local lab_host = require("hydronium_lab").host


local M = {}
local state = { config = nil, registry = nil, service = nil, fingerprint = nil, generation = 0, error = nil, request_id = nil,
  instance = tostring({}), config_path = nil, contract = nil }

M.frame_memory = { lua_heap = "64mb", max_response = "16mb", request_arena = "32mb" }

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
  local path = state.config_path or ".hydronium/lab/config.lua"
  local chunk, err = loadfile(path)
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
  _G.H = require("hydronium")
  _G.__luax = require("hydronium_luax.runtime")
  if package._hydronium_luax_searcher then return end
  local searchers = package.searchers or package.loaders
  if not searchers then return end
  -- Preserve Lua compatibility shims; compile LuaX only after Lua lookup fails.
  table.insert(searchers, 3, function(module_name)
    -- Namespaced ids declared in the project's source topology
    -- (hydronium.sources.lua / Ballad inventory) resolve like the app's dev host.
    local topology = require("hydronium_dom.dev.source_registry").try_load_project()
    local record = topology and topology:module(module_name)
    if record then
      if require("hydronium_luax.dialects").compiles(record.path) then
        return function()
          return require("hydronium_luax.loader").load(record.path, { module_id = module_name })
        end
      end
      local chunk, err = loadfile(record.path)
      if not chunk then error(err, 0) end
      return chunk
    end
    local mapped = module_name:gsub("%.", "/")
    for template in package.path:gmatch("[^;]+") do
      local lua_path = template:gsub("%?", mapped)
      if lua_path:match("%.lua$") then
        for _, extension in ipairs(require("hydronium_luax.dialects").EXTENSIONS) do
          local candidate = lua_path:gsub("%.lua$", extension)
          local file = io.open(candidate, "rb")
          if file then
            file:close()
            return function()
              return require("hydronium_luax.loader").load(candidate, { module_id = module_name })
            end
          end
        end
      end
    end
    return "\n\tno project LUAX module '" .. module_name .. "'"
  end)
  package._hydronium_luax_searcher = true
end

local function load_story(record)
  install_luax_searcher()
  if require("hydronium_luax.dialects").compiles(record.transform) then
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
  for _, story in ipairs(registry.stories) do story.renderer = story.renderer or (config.renderer == "dom" and "dom" or "ink") end
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
    state.service = require("hydronium_ink_lab").service.new(registry, {
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

function M.page(c, contract)
  if not same_origin(c) then return c:text(403, "forbidden") end
  local config = load_config()
  contract = contract or state.contract or lab_host.contract({
    base_path = config.base_path,
    renderer_stylesheet_asset = "assets/ink.css",
  })
  local h = require("hydronium").h
  install_luax_searcher()
  local Document
  local story_controls = {}
  local registry, registry_error = refresh()
  if not registry then return c:text(503, tostring(registry_error)) end
  local has_dom = config.renderer == "dom" or config.renderer == "mixed"
  for _, story in ipairs(registry.stories) do if story.renderer == "dom" then has_dom = true end end
  if has_dom then
    Document = config.document and require(config.document) or require("hydronium_lab.dom_document").Document
    contract.assets.client = (contract.base_path == "/" and "" or contract.base_path) .. "/assets/dom-lab.js"
  else
    Document = config.document and require(config.document) or require("hydronium_ink_lab.dom")
  end
  local ControlsOutlet = require("hydronium_lab.controls").ControlsOutlet
  for _, story in ipairs(registry.stories) do
    if story.controls_view then
      local storyState = require("hydronium_lab.state").new(story.args, story.controls)
      story_controls[#story_controls + 1] = h(ControlsOutlet, { story_id = story.id },
        h(require("hydronium_lab.state").Context.Provider, { value = storyState }, h(story.controls_view, { args = story.args, controls = story.controls })))
    end
  end
  local body = require("hydronium_dom.server").render_to_string(h(Document, {
    title = config.title or "Hydronium Ink Lab",
    project_name = config.project_name or config.title or "Hydronium Ink Lab",
    project_id = config.project_id or config.project_name or "hydronium-lab",
    boot = contract,
    story_controls = story_controls,
    stylesheet_url = contract.assets.stylesheet,
    client_url = contract.assets.client,
  }), { doctype = true })
  return c:bytes(200, "text/html; charset=utf-8", body, { headers = { ["Cache-Control"] = "no-store", ["X-Content-Type-Options"] = "nosniff",
    ["Referrer-Policy"] = "no-referrer", ["Content-Security-Policy"] = "default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'" } })
end

function M.redirect(c)
  local config = load_config()
  local contract = state.contract or lab_host.contract({ base_path = config.base_path })
  return c:redirect(302, contract.base_path == "/" and "/" or contract.base_path .. "/")
end

--- Mount the Meteorite adapter at an explicit prefix.  Route ownership lives
--- here instead of in the launcher, so another Lab CLI (or an application)
--- can compose the same adapter without copying its private HTTP surface.
--- @param app table Meteorite application
--- @param opts? {base_path?: string, config_path?: string, redirect_root?: boolean, memory?: table}
function M.mount(app, opts)
  opts = opts or {}
  local contract = lab_host.contract({
    base_path = opts.base_path,
    renderer_stylesheet_asset = opts.renderer_stylesheet_asset or "assets/ink.css",
  })
  if state.contract and state.contract.base_path ~= contract.base_path then
    error("hydronium_meteorite.lab: one process cannot mount multiple Lab prefixes", 2)
  end
  state.contract = contract
  state.config_path = opts.config_path or ".hydronium/lab/config.lua"
  local base, memory = contract.base_path, opts.memory or M.frame_memory
  local prefix = base == "/" and "" or base
  local page_path = base == "/" and "/" or base .. "/"

  -- Meteorite source-lifts inline handlers and therefore rejects captures.
  -- Resolve the adapter inside each handler so the emitted route remains
  -- portable across the graph-building and owned runtime Lua states.
  app:get(page_path, function(c) return require("hydronium_meteorite.lab").page(c) end)
  app:get(prefix .. "/assets/lab.css", function(c) return require("hydronium_meteorite.lab").asset(c, "lab.css") end)
  app:get(prefix .. "/assets/workbench.css", function(c) return require("hydronium_meteorite.lab").asset(c, "workbench.css") end)
  app:get(prefix .. "/assets/preview-settings.js", function(c) return require("hydronium_meteorite.lab").asset(c, "preview-settings.js") end)
  app:get(prefix .. "/assets/workbench.js", function(c) return require("hydronium_meteorite.lab").asset(c, "workbench.js") end)
  app:get(prefix .. "/assets/ink.css", function(c) return require("hydronium_meteorite.lab").asset(c, "ink.css") end)
  app:get(prefix .. "/assets/virtual_terminal.js", function(c) return require("hydronium_meteorite.lab").asset(c, "virtual_terminal.js") end)
  app:get(prefix .. "/assets/meteorite.js", function(c) return require("hydronium_meteorite.lab").asset(c, "meteorite.js") end)
  app:get(prefix .. "/dom/styles/:index", function(c) return require("hydronium_meteorite.lab").dom_style(c) end)
  app:get(prefix .. "/dom/modules", function(c) return require("hydronium_meteorite.lab").dom_modules(c) end)
  app:get(prefix .. "/dom/bundle", function(c) return require("hydronium_meteorite.lab").dom_bundle(c) end)
  app:get(prefix .. "/dom/preview", function(c) return require("hydronium_meteorite.lab").dom_preview(c) end)
  app:get(prefix .. "/ink/preview", function(c) return require("hydronium_meteorite.lab").ink_preview(c) end)
  app:get(prefix .. "/assets/dom-lab.js", function(c) return require("hydronium_meteorite.lab").asset(c, "dom-lab.js") end)
  app:get(prefix .. "/assets/dom-preview.js", function(c) return require("hydronium_meteorite.lab").asset(c, "dom-preview.js") end)
  app:get(prefix .. "/assets/ink-preview.js", function(c) return require("hydronium_meteorite.lab").asset(c, "ink-preview.js") end)
  app:get(prefix .. "/assets/dom-client/:path*", function(c) return require("hydronium_meteorite.lab").dom_asset(c) end)
  app:get(prefix .. "/catalog", function(c) return require("hydronium_meteorite.lab").catalog(c) end)
  app:post(prefix .. "/sessions", { memory = memory }, function(c) return require("hydronium_meteorite.lab").create_session(c) end)
  app:post(prefix .. "/sessions/:id/operations", { memory = memory }, function(c) return require("hydronium_meteorite.lab").operation(c) end)
  app:delete(prefix .. "/sessions/:id", function(c) return require("hydronium_meteorite.lab").close_session(c) end)
  if opts.redirect_root ~= false and base ~= "/" then
    app:get("/", function(c) return require("hydronium_meteorite.lab").redirect(c) end)
  end
  return contract
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
  if name == "meteorite.js" or name == "dom-lab.js" or name == "dom-preview.js" or name == "ink-preview.js" then
    return module_root .. "/hydronium_meteorite/client/" .. name, "text/javascript; charset=utf-8"
  end
  local ink_root = search_module("hydronium_ink_lab")
  if name == "virtual_terminal.js" and ink_root then
    return ink_root:gsub("/init%.lua$", "/client/virtual_terminal.js"), "text/javascript; charset=utf-8"
  end
  if name == "ink.css" and ink_root then
    return ink_root:gsub("/init%.lua$", "/client/ink.css"), "text/css; charset=utf-8"
  end
  local lab_root = search_module("hydronium_lab")
  if name == "workbench.css" and lab_root then
    return lab_root:gsub("/init%.lua$", "/client/workbench.css"), "text/css; charset=utf-8"
  end
  if (name == "workbench.js" or name == "preview-settings.js") and lab_root then
    return lab_root:gsub("/init%.lua$", "/client/" .. name), "text/javascript; charset=utf-8"
  end
  if name == "lab.css" and ink_root and lab_root then
    -- The stable renderer stylesheet URL is a host-built bundle. Lab supplies
    -- the workbench chrome; Ink appends only renderer-specific compatibility
    -- and terminal rules while its migration is in progress.
    return {
      lab_root:gsub("/init%.lua$", "/client/workbench.css"),
      ink_root:gsub("/init%.lua$", "/client/lab.css"),
    }, "text/css; charset=utf-8"
  end
  return nil
end

function M.asset(c, name)
  if not same_origin(c) then return c:text(403, "forbidden") end
  local path, content_type = package_client_path(name)
  if not path then return c:text(404, "not found") end
  local ok, content = pcall(function()
    if type(path) == "table" then
      local parts = {}
      for index, item in ipairs(path) do parts[index] = read(item) end
      return table.concat(parts, "\n")
    end
    return read(path)
  end)
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
  local requested = body.request
  if requested and requested.op == "open" then
    local story = state.registry and state.registry.get(requested.story)
    if story and story.renderer == "dom" then return c:json(400, { ok = false, outcome = "invalid_renderer", message = "DOM stories require a browser preview" }) end
  end
  return c:json(current:operate(c:param("id"), body, #(c:body() or "")))
end

function M.close_session(c)
  if not mutation_allowed(c) then return c:text(403, "forbidden") end
  local current = service(c)
  if not current then return c:json({ ok = true, outcome = "closed", existed = false }) end
  return c:json(current:close(c:param("id")))
end

-- The DOM client runtime is whatever hydronium_dom ships in client/: a JS
-- file at its root, or the vendored wasmoon build. Checked structurally
-- rather than against a hand-kept list, which went stale whenever the
-- runtime gained a file.
local function dom_client_file(name)
  if type(name) ~= "string" or name:find("..", 1, true) then return false end
  return name:match("^[%w_%-]+%.js$") ~= nil
    or name:match("^vendor/wasmoon/[%w_%-%.]+%.js$") ~= nil
    or name == "vendor/wasmoon/glue.wasm"
    or name == "vendor/lua-wasm/5.4.9/engine.js"
    or name == "vendor/lua-wasm/5.4.9/engine.wasm"
    or name == "vendor/lua-wasm/5.4.9/task-runtime.mjs"
    or name == "vendor/lua-wasm/5.4.9/engine.json"
    or name == "vendor/lua-wasm/5.4.9/LICENSE-Lua.html"
    or name == "vendor/lua-wasm/5.4.9/engine.js"
    or name == "vendor/lua-wasm/5.4.9/engine.wasm"
    or name == "vendor/lua-wasm/5.4.9/task-runtime.mjs"
    or name == "vendor/lua-wasm/5.4.9/engine.json"
    or name == "vendor/lua-wasm/5.4.9/LICENSE-Lua.html"
end
M.dom_client_file = dom_client_file
function M.dom_asset(c)
  if not same_origin(c) then return c:text(403, "forbidden") end
  local name = c:param("path")
  if not dom_client_file(name) then return c:text(404, "not found") end
  local module = package.searchpath("hydronium_dom", package.path)
  if not module then return c:text(503, "DOM package unavailable") end
  local path = module:gsub("/init%.lua$", "/client/") .. name
  local ok, bytes = pcall(read, path)
  if not ok then return c:text(404, "asset unavailable") end
  return c:bytes(200, name:match("%.wasm$") and "application/wasm" or "text/javascript; charset=utf-8", bytes)
end
local function dom_sources()
  local registry, err = refresh()
  if not registry then error(err, 0) end
  return require("hydronium_meteorite.dom_lab").sources(load_config(), registry)
end
function M.dom_modules(c)
  if not same_origin(c) then return c:text(403, "forbidden") end
  local ok, sources, project = pcall(dom_sources)
  if not ok then return c:json(500, { ok = false, message = tostring(sources) }) end
  local modules = {}
  for id in pairs(project) do modules[id] = sources[id] end
  return c:json({ ok = true, modules = modules, styles_revision = fingerprint(load_config().styles or {}) })
end
function M.dom_bundle(c)
  if not same_origin(c) then return c:text(403, "forbidden") end
  local ok, sources = pcall(dom_sources)
  if not ok then return c:text(500, tostring(sources)) end
  return c:bytes(200, "text/plain; charset=utf-8", require("hydronium_meteorite.dom_lab").bundle(sources), { headers = { ["Cache-Control"] = "no-store" } })
end
function M.dom_style(c)
  if not same_origin(c) then return c:text(403, "forbidden") end
  local index = tonumber(c:param("index"))
  local path = index and index % 1 == 0 and (load_config().styles or {})[index]
  if not path then return c:text(404, "not found") end
  path = lab_host.normalize_asset_path(path, "style")
  return c:bytes(200, "text/css; charset=utf-8", read(path), { headers = { ["Cache-Control"] = "no-store" } })
end
function M.dom_preview(c)
  if not same_origin(c) then return c:text(403, "forbidden") end
  local H = require("hydronium")
  local contract = state.contract or lab_host.contract({ base_path = load_config().base_path })
  local base = contract.base_path == "/" and "" or contract.base_path
  local styles = {}
  for index in ipairs(load_config().styles or {}) do styles[#styles + 1] = H.h("link", { rel = "stylesheet", href = base .. "/dom/styles/" .. index }) end
  local html = require("hydronium_dom.server").renderToString(H.h("html", nil,
    H.h("head", nil, H.h("meta", { charset = "utf-8" }), H.h("meta", { name = "viewport", content = "width=device-width,initial-scale=1" }), H.h(H.Fragment, nil, styles)),
    H.h("body", { ["data-lab-base-path"] = base }, H.h("div", { id = "preview" }), H.h("script", { type = "module", src = base .. "/assets/dom-preview.js" }))))
  return c:bytes(200, "text/html; charset=utf-8", "<!doctype html>" .. html, { headers = { ["Content-Security-Policy"] = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self'" } })
end
function M.ink_preview(c)
  install_luax_searcher()
  if not same_origin(c) then return c:text(403, "forbidden") end
  local config = load_config()
  local contract = lab_host.contract({ base_path = config.base_path, client_asset = "assets/ink-preview.js", renderer_stylesheet_asset = "assets/ink.css" })
  local H = require("hydronium")
  local assets = contract.assets
  local html = require("hydronium_dom.server").renderToString(H.h("html", { lang = "en" },
    H.h("head", {}, H.h("meta", { charset = "utf-8" }),
      H.h("link", { rel = "stylesheet", href = assets.renderer_stylesheet }),
      H.h("style", {}, "html,body{margin:0;padding:0;background:transparent;overflow:hidden} [data-lab-terminal]{margin:0;padding:0;width:max-content;transform:none}")),
    H.h("body", {}, H.h("main", { ["data-hydronium-ink-lab"] = "", ["data-lab-base-path"] = config.base_path,
      ["data-lab-project"] = (config.project_id or "lab") .. ":ink-preview" },
      H.h("div", { ["data-lab-terminal"] = "", tabindex = "0", role = "application", ["aria-label"] = "Interactive terminal preview" })),
      H.h("script", { type = "module", src = assets.client }))))
  return c:bytes(200, "text/html; charset=utf-8", "<!doctype html>" .. html)
end

function M.reset_for_test()
  if state.service then state.service:shutdown() end
  state = { config = nil, registry = nil, service = nil, fingerprint = nil, generation = 0, error = nil, request_id = nil,
    instance = tostring({}), config_path = nil, contract = nil }
end

return M
