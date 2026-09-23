-- Tool-scoped executables currently receive transitive package roots even on
-- Moonstone versions which do not yet project a tool's native Lua modules into
-- the project's top-level LUA_CPATH. Resolve LuaFileSystem from that explicit
-- package root as a compatibility bridge; normal environments take the first
-- branch and need no path surgery.
local function load_lfs()
  local ok, module = pcall(require, "lfs")
  if ok then return module end
  local root = os.getenv("MOONSTONE_PACKAGE_ROOT_LUAFILESYSTEM")
  if root and root ~= "" then
    package.cpath = table.concat({
      root .. "/lib/lua/5.1/?.so", root .. "/lib/lua/5.1/?.dylib", root .. "/lib/lua/5.1/?.dll",
      root .. "/lib/lua/5.4/?.so", root .. "/lib/lua/5.4/?.dylib", root .. "/lib/lua/5.4/?.dll",
      package.cpath,
    }, ";")
    ok, module = pcall(require, "lfs")
    if ok then return module end
  end
  error("hydronium-lab requires LuaFileSystem: " .. tostring(module), 0)
end

local lfs = load_lfs()

local M = {}

local function lua_quote(value) return string.format("%q", tostring(value)) end
local function shell_quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end

local function command_with_environment(command, environment)
  if not environment or next(environment) == nil then return command end
  local keys = {}
  for key in pairs(environment) do
    if type(key) ~= "string" or not key:match("^[A-Z_][A-Z0-9_]*$") then
      error("Lab host adapter returned an invalid environment key", 3)
    end
    keys[#keys + 1] = key
  end
  table.sort(keys)
  if package.config:sub(1, 1) == "\\" then
    local parts = {}
    for _, key in ipairs(keys) do
      local value = tostring(environment[key])
      if value:find('[\r\n"]') then error("Lab host adapter returned an unsafe Windows environment value", 3) end
      parts[#parts + 1] = 'set "' .. key .. "=" .. value .. '"'
    end
    parts[#parts + 1] = command
    return table.concat(parts, " && ")
  end
  local parts = { "env" }
  for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. shell_quote(environment[key]) end
  parts[#parts + 1] = command
  return table.concat(parts, " ")
end

local function manifest_project_name()
  local file = io.open("moonstone.toml", "rb")
  if not file then return "hydronium-lab" end
  local source = file:read("*a") or ""
  file:close()
  return source:match('[\r\n]name%s*=%s*"([^"]+)"') or "hydronium-lab"
end

local function normalize_root(path)
  if type(path) ~= "string" or path == "" then return nil, "story roots must be non-empty paths" end
  path = path:gsub("\\", "/"):gsub("^%./", ""):gsub("/+", "/"):gsub("/$", "")
  if path == "" or path:sub(1, 1) == "/" or path:match("^%a:/") then return nil, "story roots must be project-relative: " .. path end
  for segment in path:gmatch("[^/]+") do
    if segment == "." or segment == ".." then return nil, "story roots cannot escape the project: " .. path end
  end
  return path
end

local function under(path, root)
  return path:sub(1, #root + 1) == root .. "/"
end

local function normalize_roots(roots)
  if type(roots) ~= "table" or #roots == 0 then return nil, "story roots must be a non-empty list" end
  local normalized = {}
  for index, root in ipairs(roots) do
    local value, err = normalize_root(root)
    if not value then return nil, err end
    normalized[index] = value
  end
  for left = 1, #normalized do
    for right = left + 1, #normalized do
      local a, b = normalized[left], normalized[right]
      if a == b or under(a, b) or under(b, a) then
        return nil, "story roots must not duplicate or overlap: '" .. a .. "' and '" .. b .. "'"
      end
    end
  end
  return normalized
end

function M.read_config(path)
  path = path or "hydronium.lab.lua"
  local file = io.open(path, "rb")
  if not file then
    local name = manifest_project_name()
    return { roots = { "src" }, title = "Hydronium Lab", project_name = name, project_id = name,
      host = "meteorite", base_path = "/__hydronium/lab" }
  end
  file:close()
  local chunk, err = loadfile(path)
  if not chunk then return nil, err end
  local ok, config = pcall(chunk)
  if not ok then return nil, config end
  if type(config) ~= "table" then return nil, path .. " must return a table" end
  local roots, root_err = normalize_roots(config.roots or { "src" })
  if not roots then return nil, root_err end
  config.roots = roots
  config.project_name = config.project_name or manifest_project_name()
  config.project_id = config.project_id or config.project_name
  config.host = config.host or "meteorite"
  config.base_path = config.base_path or "/__hydronium/lab"
  return config
end

local function default_fs()
  return {
    mode = function(path) return lfs.symlinkattributes(path, "mode") end,
    entries = function(path)
      local values = {}
      local ok, iter, object = pcall(lfs.dir, path)
      if not ok then return nil, iter end
      for name in iter, object do
        if name ~= "." and name ~= ".." then values[#values + 1] = name end
      end
      table.sort(values)
      return values
    end,
  }
end

-- Portable, containment-preserving enumeration. Directory symlinks are not
-- followed, avoiding cycles and roots that silently escape the project.
function M.scan(config, fs)
  fs = fs or default_fs()
  local paths = {}
  local function visit(path, is_root)
    local mode = fs.mode(path)
    if mode == "directory" then
      local names, err = fs.entries(path)
      if not names then return nil, err end
      for _, name in ipairs(names) do
        if type(name) ~= "string" or name == "" or name == "." or name == ".."
          or name:find("/", 1, true) or name:find("\\", 1, true) or name:find("[%z\r\n]") then
          return nil, "filesystem returned an invalid entry under " .. path
        end
        local ok, visit_err = visit(path .. "/" .. name, false)
        if not ok then return nil, visit_err end
      end
    elseif mode == "file" and (path:match("%.stories%.lua$") or path:match("%.stories%.luax$")) then
      paths[#paths + 1] = path
    elseif is_root and mode == "link" then
      return nil, "story root must not be a symbolic link: " .. path
    elseif is_root and mode == nil then
      return nil, "story root does not exist: " .. path
    end
    return true
  end
  local roots, roots_err = normalize_roots(config.roots or { "src" })
  if not roots then return nil, roots_err end
  for _, root in ipairs(roots) do
    local ok, visit_err = visit(root, true)
    if not ok then return nil, visit_err end
  end
  table.sort(paths)
  return paths
end

local function config_source(config, paths)
  local roots, story_paths = {}, {}
  for index, root in ipairs(config.roots or { "src" }) do roots[index] = lua_quote(root) end
  for index, path in ipairs(paths) do story_paths[index] = lua_quote(path) end
  return "return {\n"
    .. "  title = " .. lua_quote(config.title or "Hydronium Lab") .. ",\n"
    .. "  project_name = " .. lua_quote(config.project_name or "hydronium-lab") .. ",\n"
    .. "  project_id = " .. lua_quote(config.project_id or config.project_name or "hydronium-lab") .. ",\n"
    .. "  base_path = " .. lua_quote(config.base_path or "/__hydronium/lab") .. ",\n"
    .. "  roots = { " .. table.concat(roots, ", ") .. " },\n"
    .. "  paths = { " .. table.concat(story_paths, ", ") .. " },\n"
    .. "}\n"
end

local function package_root_env(package_name)
  return "MOONSTONE_PACKAGE_ROOT_" .. package_name:upper():gsub("[^A-Z0-9]", "_")
end

local function expose_package_root(package_name)
  if not package_name then return true end
  local env_name = package_root_env(package_name)
  local root = os.getenv(env_name)
  if not root or root == "" then
    return nil, "Lab host package '" .. package_name .. "' is not in the active Moonstone profile (missing " .. env_name .. ")"
  end
  local candidates = {
    root .. "/src/?.lua", root .. "/src/?/init.lua",
    root .. "/lua/?.lua", root .. "/lua/?/init.lua",
    root .. "/share/lua/5.1/?.lua", root .. "/share/lua/5.1/?/init.lua",
    root .. "/?.lua", root .. "/?/init.lua",
  }
  package.path = table.concat(candidates, ";") .. ";" .. package.path
  return true
end

local function host_descriptor(config, override)
  local selected = override or config.host
  if selected == "meteorite" then
    return { id = "meteorite", package = "hydronium/meteorite", module = "hydronium_meteorite.lab_host" }
  end
  if type(selected) == "table" then
    if type(selected.module) ~= "string" or selected.module == "" then
      return nil, "Lab host table requires a module"
    end
    return { id = selected.id or selected.module, package = selected.package, module = selected.module }
  end
  if type(selected) ~= "string" or selected == "" then
    return nil, "Lab host must be 'meteorite' or an explicit Lua adapter module"
  end
  return { id = selected, module = selected }
end

function M.plan(opts)
  opts = opts or {}
  local config, config_err = M.read_config(opts.config)
  if not config then return nil, config_err end
  local paths, scan_err = M.scan(config, opts.fs)
  if not paths then return nil, scan_err end
  if #paths == 0 then return nil, "no *.stories.lua or *.stories.luax files found under " .. table.concat(config.roots, ", ") end

  local descriptor, host_err = host_descriptor(config, opts.adapter)
  if not descriptor then return nil, host_err end
  local exposed, expose_err = expose_package_root(descriptor.package)
  if not exposed then return nil, expose_err end
  local ok, adapter = pcall(require, descriptor.module)
  if not ok then return nil, "cannot load Lab host adapter '" .. descriptor.module .. "': " .. tostring(adapter) end
  if type(adapter) ~= "table" or type(adapter.plan) ~= "function" then
    return nil, "Lab host adapter '" .. descriptor.module .. "' must expose plan(input)"
  end

  local state_dir = opts.state_dir or ".hydronium/lab"
  local config_path = state_dir .. "/config.lua"
  local planned, host_plan = pcall(adapter.plan, { config = config, config_path = config_path, paths = paths, state_dir = state_dir,
    host = opts.host or "127.0.0.1", port = tonumber(opts.port) or 6100 })
  if not planned then return nil, "Lab host adapter '" .. descriptor.module .. "' failed: " .. tostring(host_plan) end
  if type(host_plan) ~= "table" or type(host_plan.files) ~= "table" or type(host_plan.command) ~= "string" then
    return nil, "Lab host adapter '" .. descriptor.module .. "' returned an invalid plan"
  end
  host_plan.files[config_path] = config_source(config, paths)
  host_plan.paths, host_plan.adapter = paths, descriptor.id
  return host_plan
end

local function mkdir_p(path)
  local current = ""
  for segment in path:gmatch("[^/]+") do
    current = current == "" and segment or current .. "/" .. segment
    local mode = lfs.attributes(current, "mode")
    if mode == nil then
      local ok, err = lfs.mkdir(current)
      if not ok then return nil, err end
    elseif mode ~= "directory" then
      return nil, current .. " is not a directory"
    end
  end
  return true
end

function M.prepare(opts)
  local plan, err = M.plan(opts)
  if not plan then return nil, err end
  if opts and opts.dry_run then return plan end
  local ok, mkdir_err = mkdir_p(opts and opts.state_dir or ".hydronium/lab")
  if not ok then return nil, mkdir_err end
  for path, content in pairs(plan.files) do
    local file, open_err = io.open(path, "wb")
    if not file then return nil, open_err end
    file:write(content)
    file:close()
  end
  return plan
end

function M.run(opts)
  opts = opts or {}
  local plan, err = M.prepare(opts)
  if not plan then return nil, err end
  if opts.dry_run then return plan end
  io.stderr:write(string.format("Hydronium Lab: %s (%d story files; %s)\n", plan.url or "host-managed URL", #plan.paths, plan.adapter))
  local ok, why, code = os.execute(command_with_environment(plan.command, plan.environment))
  if type(ok) == "number" then return ok == 0 and true or nil, "Lab host exited with status " .. tostring(ok) end
  if ok == true and (code == nil or code == 0) then return true end
  return nil, "Lab host exited with status " .. tostring(code or why)
end

M.command_with_environment = command_with_environment
return M
