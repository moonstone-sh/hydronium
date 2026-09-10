local alter = require("alter")
local jsonc = require("alter_jsonc")

local luals = {}

---Configures .luarc.json with Hydronium LuaX LSP plugin and workspace library paths.
---@param target_dir string Project destination directory
---@param opts? { interpreter?: string, dry_run?: boolean, luax?: boolean, dom?: boolean, bare_dom?: boolean, meteorite?: boolean }
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
  local enable_meteorite = opts.meteorite == true

  -- Meteorite generates real per-route LuaCATS classes into
  -- `.meteorite/aids/lua` on every `meteorite graph`/`meteorite build`
  -- (src/codegen/luals_aids.lua): `MeteoriteParams_<route_id>`,
  -- `MeteoriteQuery_<route_id>`, `MeteoriteContext_<route_id>`, plus
  -- path-literal `---@field get fun(self: MeteoriteApp, path: "/users/:id",
  -- handler: fun(c: MeteoriteContext_get_user): any)` overloads on
  -- `MeteoriteApp`. Those overloads really do give `c` a specific type
  -- inside an ordinary `app:get(path, function(c) ... end)` -- but only
  -- if the aids are on LuaLS's path, and Hydronium's scaffolded
  -- `.luarc.json` never put them there.
  --
  -- Verified live (lua-language-server 3.18.2-dev, real
  -- textDocument/completion against a real scaffolded project), asking
  -- for completions at `c.params.` inside
  -- `app:get("/hydronium-src/:path*", function(c)`:
  --   before: 100 items, all buffer word-completions, zero type info
  --   after:  exactly 1 item -- `path` -- i.e. MeteoriteParams_route_1
  -- A route with no declared params correctly stays on the generic
  -- `MeteoriteContext` instead of getting a wrong specific type.
  --
  -- Both entries are needed: `workspace.library` makes LuaLS load the
  -- files, `runtime.path` lets `require("meteorite")` resolve to the
  -- generated stub rather than to nothing.
  local meteorite_aids_dir = ".meteorite/aids/lua"

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
  if enable_meteorite then
    table.insert(library_paths, meteorite_aids_dir)
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
  --
  -- 1c. `.meteorite/aids/lua/?.lua` + `/?/init.lua` do the same job for
  -- Meteorite's generated aids (see the comment on `meteorite_aids_dir`
  -- above): they let `require("meteorite")` resolve to the generated
  -- stub that declares `MeteoriteApp`'s typed per-route overloads.
  --
  -- Both searcher sets are applied through ONE cursor. They used to be
  -- two `runtime:at("path")` blocks, which silently dropped `?.luax`:
  -- a second `at("path")` cursor does not observe the first cursor's
  -- pending `set()`, so it still reported kind "none", re-`set()` a
  -- fresh two-element list, and clobbered the `.luax` searcher. Caught
  -- by scaffolding a real project and reading the emitted .luarc.json,
  -- not by the unit tests -- keep this as a single cursor.
  local runtime_path_additions = {}
  if enable_luax then
    table.insert(runtime_path_additions, "?.luax")
  end
  if enable_meteorite then
    table.insert(runtime_path_additions, meteorite_aids_dir .. "/?.lua")
    table.insert(runtime_path_additions, meteorite_aids_dir .. "/?/init.lua")
  end
  if #runtime_path_additions > 0 then
    local runtime_path = runtime:at("path")
    if runtime_path:kind() == "none" then
      -- Preserve the two searchers LuaLS ships by default; they stop
      -- being implicit the moment `runtime.path` is set at all.
      runtime_path:set({ "?.lua", "?/init.lua" })
    end
    local entries = runtime_path:ensure_array()
    for _, entry in ipairs(runtime_path_additions) do
      entries:append_unique(entry)
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
