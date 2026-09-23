-- Lab CLI host adapter for Meteorite.  It implements the small planning
-- protocol consumed by hydronium/lab-cli without making that CLI depend on
-- Meteorite internals.
local M = { id = "meteorite" }

local function lua_quote(value) return string.format("%q", tostring(value)) end

-- Keep the planning entry self-contained. `hydronium-lab` loads adapters in
-- its isolated tool scope before the served application's development
-- dependencies are projected, so importing renderer/runtime modules here
-- would make a valid adapter unreachable. `lab.mount` validates the same
-- public invariant again when Meteorite evaluates the generated graph.
local function normalize_base_path(value)
  value = value or "/__hydronium/lab"
  if type(value) ~= "string" or value == "" then error("Lab base_path must be a non-empty string", 3) end
  value = value:gsub("\\", "/"):gsub("/+", "/")
  if value:sub(1, 1) ~= "/" then value = "/" .. value end
  if #value > 1 then value = value:gsub("/$", "") end
  if value:find("[%z\r\n?#]") then error("Lab base_path must be a URL path without a query or fragment", 3) end
  for segment in value:gmatch("[^/]+") do
    if segment == "." or segment == ".." then error("Lab base_path cannot contain dot segments", 3) end
  end
  return value
end

local runtime_package_envs = {
  "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_METEORITE",
  "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_LAB",
  "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK_LAB",
  "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_DOM",
  "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_LUAX",
  "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_CORE",
  "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_INK",
  "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_OKLAB_UTILS",
  "MOONSTONE_PACKAGE_ROOT_LUA_CJSON",
}

local module_source = debug.getinfo(1, "S").source
if module_source:sub(1, 1) == "@" then module_source = module_source:sub(2) end
local own_package_root = module_source:match("^(.*)/src/hydronium_meteorite/lab_host%.lua$")
  or module_source:match("^(.*)/hydronium_meteorite/lab_host%.lua$")

local function package_scope_source()
  local names = {}
  for index, name in ipairs(runtime_package_envs) do names[index] = lua_quote(name) end
  return string.format([=[-- Lab libraries are development dependencies while Meteorite is a tool.
-- Moonstone deliberately keeps tool Lua scopes isolated, exposing project
-- packages as explicit roots instead. Project only the adapter's declared
-- runtime closure into this generated development graph.
local function expose_lab_package(env_name)
  local root = os.getenv(env_name)
  if not root or root == "" then error("Hydronium Lab dependency is unavailable: " .. env_name, 0) end
  package.path = table.concat({
    root .. "/src/?.lua", root .. "/src/?/init.lua",
    root .. "/lua/?.lua", root .. "/lua/?/init.lua",
    root .. "/share/lua/5.1/?.lua", root .. "/share/lua/5.1/?/init.lua",
    root .. "/?.lua", root .. "/?/init.lua", package.path,
  }, ";")
  package.cpath = table.concat({
    root .. "/lib/lua/5.1/?.so", root .. "/lib/lua/5.1/?.dylib", root .. "/lib/lua/5.1/?.dll",
    root .. "/lib/lua/5.4/?.so", root .. "/lib/lua/5.4/?.dylib", root .. "/lib/lua/5.4/?.dll", package.cpath,
  }, ";")
end
for _, env_name in ipairs({ %s }) do expose_lab_package(env_name) end

]=], table.concat(names, ", "))
end

local function runtime_environment()
  local lua_paths, c_paths, environment = {}, {}, {}
  for _, env_name in ipairs(runtime_package_envs) do
    local root = os.getenv(env_name)
    if (not root or root == "") and env_name == "MOONSTONE_PACKAGE_ROOT_HYDRONIUM_METEORITE" then
      root = own_package_root
    end
    if not root or root == "" then
      error("Hydronium Lab dependency is unavailable: " .. env_name, 0)
    end
    environment[env_name] = root
    lua_paths[#lua_paths + 1] = root .. "/src/?.lua"
    lua_paths[#lua_paths + 1] = root .. "/src/?/init.lua"
    lua_paths[#lua_paths + 1] = root .. "/lua/?.lua"
    lua_paths[#lua_paths + 1] = root .. "/lua/?/init.lua"
    lua_paths[#lua_paths + 1] = root .. "/share/lua/5.1/?.lua"
    lua_paths[#lua_paths + 1] = root .. "/share/lua/5.1/?/init.lua"
    lua_paths[#lua_paths + 1] = root .. "/?.lua"
    lua_paths[#lua_paths + 1] = root .. "/?/init.lua"
    for _, extension in ipairs({ "so", "dylib", "dll" }) do
      c_paths[#c_paths + 1] = root .. "/lib/lua/5.1/?." .. extension
      c_paths[#c_paths + 1] = root .. "/lib/lua/5.4/?." .. extension
    end
  end
  lua_paths[#lua_paths + 1] = os.getenv("LUA_PATH") or ";;"
  c_paths[#c_paths + 1] = os.getenv("LUA_CPATH") or ";;"
  environment.LUA_PATH = table.concat(lua_paths, ";")
  environment.LUA_CPATH = table.concat(c_paths, ";")
  return environment
end

--- @param input {config: table, paths: string[], state_dir: string, host: string, port: integer}
function M.plan(input)
  local base_path = normalize_base_path(input.config.base_path)
  local graph_input = input.state_dir .. "/main.lua"
  local main_lua = package_scope_source() .. string.format([=[local meteorite = require("meteorite")
local lab = require("hydronium_meteorite.lab")

local app = meteorite.app({
  name = "hydronium-lab", host = %s, port = %d,
  -- Story/component code is a runtime input. Meteorite restarts the isolated
  -- Lab process for it; route topology changes only with generated host state.
  dev_watch = {
    graph = { %s, %s, "moonstone.toml" },
    runtime = %s,
  },
})

lab.mount(app, {
  base_path = %s,
  config_path = %s,
  redirect_root = true,
})

return app
]=], lua_quote(input.host), input.port, lua_quote(input.state_dir), lua_quote(input.config_path),
    M.lua_array(input.config.roots or { "src" }), lua_quote(base_path), lua_quote(input.config_path))

  return {
    files = { [graph_input] = main_lua },
    command = table.concat({
      "meteorite dev --mode hybrid_dev --backend fast_http --hybrid-profile single_owner",
      "--router-dispatch param_matchers --graph-input " .. graph_input,
      "--lua-root .moonstone/env/libexec/luajit",
    }, " "),
    environment = runtime_environment(),
    url = "http://" .. input.host .. ":" .. tostring(input.port) .. base_path .. "/",
  }
end

function M.lua_array(values)
  local encoded = {}
  for index, value in ipairs(values) do encoded[index] = lua_quote(value) end
  return "{ " .. table.concat(encoded, ", ") .. " }"
end

M.runtime_package_envs = runtime_package_envs

return M
