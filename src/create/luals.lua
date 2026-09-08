local alter = require("alter")
local jsonc = require("alter_jsonc")

local luals = {}

---Configures .luarc.json with Hydronium LuaX LSP plugin and workspace library paths.
---@param target_dir string Project destination directory
---@param opts? { interpreter?: string, dry_run?: boolean }
---@return table|nil result, string|nil err
function luals.configure(target_dir, opts)
  opts = opts or {}
  local config_path = target_dir .. "/.luarc.json"
  config_path = config_path:gsub("/+", "/")

  local interpreter = opts.interpreter or "lua@5.4"
  local lua_ver_str = interpreter:match("5%.%d") or "5.4"
  local runtime_version = "Lua " .. lua_ver_str

  local plugin_rel_path = ".moonstone/env/share/lua/" .. lua_ver_str .. "/hydronium_luax/luals/init.lua"
  local library_rel_path = ".moonstone/env/share/lua/" .. lua_ver_str

  if opts.dry_run then
    return {
      changed = true,
      config_path = config_path,
      runtime_version = runtime_version,
      plugin = plugin_rel_path,
    }
  end

  local doc, err = alter.open(config_path, {
    backend = jsonc,
    create = true,
    default_text = "{\n  \"$schema\": \"https://raw.githubusercontent.com/LuaLS/vscode-lua/master/setting/schema.json\"\n}\n",
  })
  if not doc then
    return nil, err
  end

  -- 1. runtime.version
  local runtime = doc:at("runtime"):ensure_object()
  runtime:at("version"):set(runtime_version)

  -- 2. runtime.plugin
  local plugin_cursor = runtime:at("plugin")
  local plugin_kind = plugin_cursor:kind()
  if plugin_kind == "string" then
    local current = plugin_cursor:get()
    if current ~= plugin_rel_path then
      plugin_cursor:set({ current, plugin_rel_path })
    end
  else
    plugin_cursor:ensure_array():append_unique(plugin_rel_path)
  end

  -- 3. workspace.library
  local workspace = doc:at("workspace"):ensure_object()
  workspace:at("library"):ensure_array():append_unique(library_rel_path)

  -- 4. files.associations
  local files = doc:at("files"):ensure_object()
  local associations = files:at("associations"):ensure_object()
  associations:at("*.luax"):set("lua")

  local commit_res, commit_err = doc:commit()
  if not commit_res then
    return nil, commit_err
  end

  return {
    changed = commit_res.changed,
    config_path = config_path,
    runtime_version = runtime_version,
    plugin = plugin_rel_path,
  }
end

return luals
