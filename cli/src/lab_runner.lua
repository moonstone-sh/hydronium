-- Turnkey Hydronium Lab launcher. Generated files are private dev state under
-- `.hydronium/lab`; the user's application graph is never edited.
local M = {}

local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
local function lua_quote(value) return string.format("%q", tostring(value)) end

local function manifest_project_name()
  local file = io.open("moonstone.toml", "rb")
  if not file then return "hydronium-lab" end
  local source = file:read("*a") or ""
  file:close()
  return source:match('[\r\n]name%s*=%s*"([^"]+)"') or "hydronium-lab"
end

local function read_config(path)
  path = path or "hydronium.lab.lua"
  local file = io.open(path, "rb")
  if not file then return { roots = { "src" }, title = "Hydronium Ink Lab", project_name = manifest_project_name() } end
  file:close()
  local chunk, err = loadfile(path)
  if not chunk then return nil, err end
  local ok, config = pcall(chunk)
  if not ok then return nil, config end
  if type(config) ~= "table" then return nil, path .. " must return a table" end
  config.roots = config.roots or { "src" }
  config.project_name = config.project_name or manifest_project_name()
  config.project_id = config.project_id or config.project_name
  return config
end

function M.scan(config, capture)
  capture = capture or function(command)
    local process = assert(io.popen(command, "r"))
    local output = process:read("*a") or ""
    local ok = process:close()
    if ok == nil or ok == false then return nil, "story scan failed" end
    return output
  end
  local roots = {}
  for _, root in ipairs(config.roots or { "src" }) do roots[#roots + 1] = quote(root) end
  local command = "find " .. table.concat(roots, " ")
    .. " -type f \\( -name '*.stories.lua' -o -name '*.stories.luax' \\) -print 2>/dev/null | LC_ALL=C sort"
  local output, err = capture(command)
  if not output then return nil, err end
  local paths = {}
  for path in output:gmatch("[^\r\n]+") do paths[#paths + 1] = path:gsub("^%./", "") end
  table.sort(paths)
  return paths
end

function M.generated_files(config, paths, opts)
  opts = opts or {}
  local roots, story_paths = {}, {}
  for _, root in ipairs(config.roots or { "src" }) do roots[#roots + 1] = lua_quote(root) end
  for _, path in ipairs(paths) do story_paths[#story_paths + 1] = lua_quote(path) end
  local config_lua = "return {\n  title = " .. lua_quote(config.title or "Hydronium Ink Lab")
    .. ",\n  project_name = " .. lua_quote(config.project_name or "hydronium-lab")
    .. ",\n  project_id = " .. lua_quote(config.project_id or config.project_name or "hydronium-lab")
    .. ",\n  roots = { " .. table.concat(roots, ", ") .. " },\n  paths = { " .. table.concat(story_paths, ", ") .. " },\n}\n"
  local host, port = opts.host or "127.0.0.1", tonumber(opts.port) or 6100
  local main_lua = string.format([=[local meteorite = require("meteorite")
local app = meteorite.app({
  name = "hydronium-lab", host = %q, port = %d,
  -- Story/component code is a runtime input. Meteorite restarts the isolated
  -- Lab process for it, which clears require() state safely; the graph itself
  -- changes only when Lab configuration/generated routes change.
  dev_watch = { graph = { ".hydronium/lab", "hydronium.lab.lua", "moonstone.toml" }, runtime = { "src" } },
})

-- A Lab frame is a richly styled cell grid, not an ordinary API response.
-- Keep this development-only budget explicit: the normal hybrid profile's
-- 2 MiB Lua heap is too small to encode a default 80×24 snapshot reliably.
-- Keep headroom for a practical workbench canvas (for example 160×96): its
-- canonical Ink frame and JSON-safe styled-cell projection coexist briefly
-- during an operation. This is local development infrastructure, never an
-- application route profile.
-- Meteorite's JSON encoder builds the response buffer from this arena.  A
-- full 160×96 styled-cell snapshot is several MiB before transport, so the
-- ordinary 256 KiB/1 MiB request arenas would fail during encoding even with
-- a generous Lua heap.
local lab_frame_memory = { lua_heap = "64mb", max_response = "16mb", request_arena = "32mb" }

app:get("/__hydronium/lab/", function(c) return require("hydronium_meteorite.lab").page(c) end)
app:get("/__hydronium/lab/assets/lab.css", function(c) return require("hydronium_meteorite.lab").asset(c, "lab.css") end)
app:get("/__hydronium/lab/assets/virtual_terminal.js", function(c) return require("hydronium_meteorite.lab").asset(c, "virtual_terminal.js") end)
app:get("/__hydronium/lab/assets/meteorite.js", function(c) return require("hydronium_meteorite.lab").asset(c, "meteorite.js") end)
app:get("/__hydronium/lab/catalog", function(c) return require("hydronium_meteorite.lab").catalog(c) end)
app:post("/__hydronium/lab/sessions", { memory = lab_frame_memory }, function(c) return require("hydronium_meteorite.lab").create_session(c) end)
app:post("/__hydronium/lab/sessions/:id/operations", { memory = lab_frame_memory }, function(c) return require("hydronium_meteorite.lab").operation(c) end)
app:delete("/__hydronium/lab/sessions/:id", function(c) return require("hydronium_meteorite.lab").close_session(c) end)
app:get("/", function(c) return c:redirect(302, "/__hydronium/lab/") end)

return app
]=], host, port)
  return { [".hydronium/lab/config.lua"] = config_lua, [".hydronium/lab/main.lua"] = main_lua }
end

function M.prepare(opts)
  opts = opts or {}
  local config, config_err = read_config(opts.config)
  if not config then return nil, config_err end
  local paths, scan_err = M.scan(config, opts.capture)
  if not paths then return nil, scan_err end
  if #paths == 0 then return nil, "no *.stories.lua or *.stories.luax files found under " .. table.concat(config.roots, ", ") end
  local files = M.generated_files(config, paths, opts)
  if opts.dry_run then return { paths = paths, files = files } end
  os.execute("mkdir -p .hydronium/lab")
  for path, content in pairs(files) do
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    file:write(content)
    file:close()
  end
  return { paths = paths, files = files }
end

function M.command(opts)
  opts = opts or {}
  return table.concat({
    "meteorite dev --mode hybrid_dev --backend fast_http --hybrid-profile single_owner",
    "--router-dispatch param_matchers --graph-input .hydronium/lab/main.lua",
    "--lua-root .moonstone/env/libexec/luajit",
  }, " ")
end

function M.run(opts)
  local prepared, err = M.prepare(opts)
  if not prepared then return nil, err end
  if opts and opts.dry_run then return prepared end
  io.stderr:write(string.format("Hydronium Lab: http://%s:%d/__hydronium/lab/ (%d stories files)\n",
    opts.host or "127.0.0.1", tonumber(opts.port) or 6100, #prepared.paths))
  local ok, why, code = os.execute(M.command(opts))
  if type(ok) == "number" then return ok == 0 and true or nil, "Meteorite exited with status " .. tostring(ok) end
  if ok == true and (code == nil or code == 0) then return true end
  return nil, "Meteorite exited with status " .. tostring(code or why)
end

return M
