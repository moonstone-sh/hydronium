--[[
  Hydronium LUAX Loader -- serve-time `.luax` -> Lua transform.

  Generalizes the ad hoc `load_luax` pattern that lived inline in
  examples/meteorite_ssr/src/views/App.lua: compile a `.luax` file on
  demand and return its module result, exactly like `require` would for
  a plain `.lua` file. Every hydronium app should require THIS instead of
  hand-rolling its own copy.

  Why this belongs server-side, not shipped into the browser's Lua VM:
  the compiler (hydronium_luax.compile) is pure Lua and already runs on
  every request under Meteorite's hybrid mode (a fresh Lua state per
  request). The browser only ever needs the compiled `.lua` output --
  shipping the compiler itself into wasmoon would double the WASM
  payload and reimplement file IO inside a sandboxed VM for zero benefit,
  since compiled output is identical either way (the compiler emits JSX
  expression containers verbatim, so client vs. server compilation of the
  same source produces the same Lua).

  Caching: keyed by (path, source content). The file read is intentionally
  kept: calling `stat` through `io.popen` can deadlock when several
  Meteorite request threads refresh modules at once. A cache hit skips the
  compile, and content identity catches same-size edits within one timestamp
  tick.
--]]

-- Depends on the compiler module directly, not the top-level
-- `hydronium_luax` package (which requires this loader) -- avoids a
-- require cycle.
local compiler = require("hydronium_luax.compiler")
local dialects = require("hydronium_luax.dialects")

local M = {}

-- path -> { source = string, result = <compiled module return value> }
local cache = {}

-- path -> { source = string, code = string, compiled = <compiler result> }
-- Kept separate from `cache` rather than folded into it: `M.load`'s
-- entries hold an EXECUTED module's return value, `M.source`'s hold
-- un-executed text, and a caller of one must never be handed the other
-- just because the file's source happened to match.
local source_cache = {}

local function read_source(path)
  local file = io.open(path, "r")
  if not file then
    error("hydronium_luax.loader: cannot open " .. path, 0)
  end
  local source = file:read("*a")
  file:close()
  return source
end

-- Paths already reported on, so a module recompiled on every edit does not
-- reprint the same warning forever. Keyed by path .. "\0" .. first line.
local warned = {}

--- Reports setups that declare signals but take no `scope` parameter.
---
--- `hydronium_luax.transforms.refresh` deliberately refuses to rewrite those
--- (it never invents the `scope` binding), which is correct -- but the
--- consequence is that every one of those signals silently loses its value on
--- each hot swap. Silent state loss is the exact failure the refresh pass
--- exists to remove, so say it out loud once per compile result. Callers that
--- want the data rather than the message read `compiled.refresh.missing_scope`
--- directly; pass `options.quiet = true` to suppress the print entirely.
--- @param path string
--- @param compiled table
--- @param quiet boolean|nil
local function report_missing_scope(path, compiled, quiet)
  if quiet then return end
  local refresh = compiled and compiled.refresh
  local entries = refresh and refresh.missing_scope
  if type(entries) ~= "table" or #entries == 0 then return end
  for _, entry in ipairs(entries) do
    local key = path .. "\0" .. tostring(entry.setup) .. "\0" .. tostring(entry.line)
    if not warned[key] then
      warned[key] = true
      io.stderr:write(string.format(
        "hydronium: %s:%s: `%s` declares signal(s) %s but takes no `scope` parameter, "
          .. "so their values will NOT survive a hot swap. Change its setup to "
          .. "`function(props, scope)` to opt in.\n",
        path, tostring(entry.line or "?"), tostring(entry.setup),
        table.concat(entry.signals or {}, ", ")))
    end
  end
end

--- Compile and run `path` (a `.luax` file), returning its module result.
--- Recompiles automatically whenever the file's content changes; otherwise
--- returns the cached result after one ordinary file read.
--- @param path string
--- @param options table|nil forwarded to hydronium_luax.compile (filename
---   defaults to `path`, runtime defaults to "hydronium")
function M.load(path, options)
  local source = read_source(path)
  local entry = cache[path]

  if entry and entry.source == source then
    return entry.result
  end

  local opts = {}
  if options then
    for k, v in pairs(options) do
      opts[k] = v
    end
  end
  opts.filename = opts.filename or path
  opts.runtime = opts.runtime or "hydronium"

  local compiled = dialects.of(path) == "markdown" and dialects.compile(source, opts) or compiler.compile(source, opts)
  report_missing_scope(path, compiled, opts.quiet)

  local load_fn = loadstring or load
  local chunk, err = load_fn(compiled.code, "@" .. path)
  if not chunk then
    error("hydronium_luax.loader: syntax error loading compiled .luax [" .. path .. "]: " .. tostring(err), 0)
  end

  local result = chunk()
  cache[path] = { source = source, result = result }
  return result
end

--- Compile `path` (a `.luax` file) and return its compiled Lua SOURCE
--- TEXT, without executing it -- the same content-keyed compile-on-demand
--- as `M.load`, stopping one step earlier.
---
--- This is what a dev server needs in order to hand a freshly compiled
--- module to a client HMR runtime (hydronium_dom/client/hmr.js) over
--- HTTP: the browser's Lua VM wants the compiled chunk to install as
--- `package.preload[id]`, and must NOT have the module executed here, in
--- the server's own state, where its `require`s and its DOM host do not
--- belong. `M.load` deliberately runs the chunk, so it cannot serve this
--- purpose; everything up to that point is identical.
---
--- Returns the code plus the compiler's own result table (source map,
--- refresh-pass stats, ...) for a caller that wants to report on the
--- compile rather than only ship its output.
--- @param path string
--- @param options table|nil forwarded to hydronium_luax.compile, exactly as M.load
--- @return string code, table compiled
function M.source(path, options)
  local source = read_source(path)
  local entry = source_cache[path]

  if entry and entry.source == source then
    return entry.code, entry.compiled
  end

  local opts = {}
  if options then
    for k, v in pairs(options) do
      opts[k] = v
    end
  end
  opts.filename = opts.filename or path
  opts.runtime = opts.runtime or "hydronium"

  local compiled = dialects.of(path) == "markdown" and dialects.compile(source, opts) or compiler.compile(source, opts)
  report_missing_scope(path, compiled, opts.quiet)
  source_cache[path] = { source = source, code = compiled.code, compiled = compiled }
  return compiled.code, compiled
end

--- Drop a cached entry (or the whole cache with no argument). Not needed
--- for normal content-based invalidation -- exposed for tests and for a
--- long-lived process that wants to force a reload.
function M.invalidate(path)
  if path then
    cache[path] = nil
    source_cache[path] = nil
  else
    cache = {}
    source_cache = {}
  end
end

local installed_searcher

--- Enable ordinary require("views.Home") for .luax modules on package.path.
--- Register once in each Lua VM, before loading application modules.
--- Existing Lua and native module loaders retain their normal precedence.
function M.install()
  if installed_searcher then return installed_searcher end
  local searchers = package.searchers or package.loaders
  installed_searcher = function(id)
    if type(id) ~= "string" or not id:match("^[%w_%.%-]+$") or id:find("..", 1, true) then
      return "\n\tinvalid LUAX module id"
    end
    local relative = id:gsub("%.", "/")
    local tried = {}
    for pattern in package.path:gmatch("[^;]+") do
      if pattern:match("%.lua$") then
        for _, extension in ipairs(dialects.EXTENSIONS) do
          local path = pattern:gsub("%.lua$", extension):gsub("%?", relative)
          local file = io.open(path, "r")
          if file then
            file:close()
            return function() return M.load(path) end, path
          end
          tried[#tried + 1] = "\n\tno file '" .. path .. "'"
        end
      end
    end
    return table.concat(tried)
  end
  table.insert(searchers, installed_searcher)
  return installed_searcher
end

return M
