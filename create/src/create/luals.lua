local alter = require("alter")
local jsonc = require("alter_jsonc")

local luals = {}

---Configures .luarc.json with Hydronium LuaX LSP plugin and workspace library paths.
---@param target_dir string Project destination directory
---@param opts? { interpreter?: string, dry_run?: boolean, luax?: boolean, dom?: boolean, bare_dom?: boolean }
---@return table|nil result, string|nil err
function luals.configure(target_dir, opts)
  opts = opts or {}
  local config_path = target_dir .. "/.luarc.json"
  config_path = config_path:gsub("/+", "/")

  local interpreter = opts.interpreter or "luajit@2.1"
  local is_luajit = interpreter:match("^luajit@") ~= nil
  local lua_ver_str = is_luajit and "5.1" or (interpreter:match("5%.%d") or "5.4")
  local runtime_version = is_luajit and "LuaJIT" or ("Lua " .. lua_ver_str)
  local enable_luax = opts.luax ~= false
  local enable_dom = opts.dom ~= false
  local enable_bare_dom = opts.bare_dom == true

  local plugin_rel_path = ".moonstone/env/share/lua/" .. lua_ver_str .. "/hydronium_luax/luals/init.lua"
  local library_paths = {
    ".moonstone/env/share/lua/" .. lua_ver_str,
  }
  if enable_luax then
    table.insert(library_paths, ".moonstone/env/libexec/hydronium-luax/types")
  end
  if enable_dom then
    table.insert(library_paths, ".moonstone/env/libexec/hydronium-dom/types")
  end
  if enable_bare_dom then
    table.insert(library_paths, ".moonstone/env/libexec/hydronium-dom/ambient-types")
  end

  if opts.dry_run then
    return {
      changed = true,
      config_path = config_path,
      runtime_version = runtime_version,
      plugin = enable_luax and plugin_rel_path or nil,
      libraries = library_paths,
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

  -- 1b. runtime.path -- without the "?.luax" searcher LuaLS's own
  -- require-resolution never matches a `.luax` file at all (it only
  -- tries "?.lua"/"?/init.lua" by default), so `---@module "path.to.Foo"`
  -- above a `loader.load("path/to/Foo.luax")` call has nothing to
  -- resolve against and silently gives no typing -- verified: adding
  -- this one entry is what makes `---@module` deliver full prop
  -- checking (missing-fields, param-type-mismatch, ...) through
  -- loader.load, confirmed live against a real lua-language-server
  -- --check run. Keeps the two Lua searchers LuaLS ships by default,
  -- just adds `.luax` alongside them.
  if enable_luax then
    local runtime_path = runtime:at("path")
    if runtime_path:kind() == "none" then
      runtime_path:set({ "?.lua", "?/init.lua", "?.luax" })
    else
      runtime_path:ensure_array():append_unique("?.luax")
    end
  end

  -- 2. runtime.plugin
  if enable_luax then
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
  end

  -- 3. workspace.library
  local workspace = doc:at("workspace"):ensure_object()
  local library = workspace:at("library"):ensure_array()
  for _, path in ipairs(library_paths) do
    library:append_unique(path)
  end

  -- 4. files.associations
  if enable_luax then
    local files = doc:at("files"):ensure_object()
    local associations = files:at("associations"):ensure_object()
    associations:at("*.luax"):set("lua")
  end

  local commit_res, commit_err = doc:commit()
  if not commit_res then
    return nil, commit_err
  end

  return {
    changed = commit_res.changed,
    config_path = config_path,
    runtime_version = runtime_version,
    plugin = enable_luax and plugin_rel_path or nil,
    libraries = library_paths,
  }
end

return luals
