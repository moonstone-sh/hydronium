--[[
  hydronium-cli build_verify -- M3: "load every produced Lua chunk in a
  fresh isolated Lua state and fail the build if any errors."

  Generalizes examples/spa_hash_demo/verify_chunk_isolated.lua (read that
  file first): its own `load(src); chunk()` core is preserved verbatim as
  the harness this module writes to a temp file and runs, once per chunk,
  in a REAL CHILD PROCESS with LUA_PATH/LUA_CPATH explicitly cleared --
  not merely called in-process via `load()`, which would run inside
  `hydronium build`'s own already-`moon sync`ed process, whose LUA_PATH
  already has every hydronium package on it. Calling `load()` there would
  let a chunk that is secretly missing a bundled module accidentally
  `require()` the real thing off this process's own path and pass, which
  is exactly the silent-failure class this whole task is about (see the
  top-level brief: "an `unpack` call that passed 1019 LuaJIT tests and was
  fatal in the browser"). A genuinely separate process with no hydronium
  source on its path is the only way "loads and executes cleanly" is a
  real claim about the CHUNK rather than about this process's environment.
  router/app-specific assertions from the original script are deliberately
  NOT generalized here -- they were specific to that one example's bundle
  contents; this only proves "loads and executes", the same thing M3 asks
  for and nothing more.

  WHICH ASSETS COUNT AS A CHUNK: kind == "hy_chunk", the format
  client.bundle emits (build/src/hydronium_ballad/plugins/client.lua) --
  the one output designed to be self-contained (package_preload_v1: every
  module it needs travels inside it), so "loads with no outside LUA_PATH"
  is a meaningful claim for it specifically, unlike a plain hy_module or a
  static asset.
--]]

local M = {}

M.VERIFIABLE_KIND = "hy_chunk"

--- The isolated-process harness. Kept as a Lua string (not a checked-in
--- file) so this module has no data file of its own to install/locate --
--- it is written to a temp path fresh for each verify run.
local HARNESS = [==[
local chunk_path = arg[1]
if not chunk_path then
  io.stderr:write("usage: luajit <harness> <chunk path>\n")
  os.exit(2)
end
local f, open_err = io.open(chunk_path, "rb")
if not f then
  io.stderr:write("cannot open chunk: " .. tostring(open_err) .. "\n")
  os.exit(1)
end
local src = f:read("*a")
f:close()
local loaded, load_err = load(src, "@" .. chunk_path)
if not loaded then
  io.stderr:write("PARSE ERROR: " .. tostring(load_err) .. "\n")
  os.exit(1)
end
local ok, exec_err = pcall(loaded)
if not ok then
  io.stderr:write("EXECUTE ERROR: " .. tostring(exec_err) .. "\n")
  os.exit(1)
end
io.stdout:write("OK: " .. chunk_path .. " (" .. #src .. " bytes)\n")
os.exit(0)
]==]

--- Collects every hy_chunk asset written to disk.
---
--- NOT read from execute()'s own sink_results: a directory sink's own
--- result (`sink.result.assets`) is a single synthetic `kind = "sink"`
--- summary asset (verified for real: printing `sink.result.assets` for
--- examples/spa_hash_demo's real build shows exactly one asset, kind
--- "sink", virtual_path "dist" -- ballad.cli's own `play` command's
--- "assets=" count is counting that same one-element list), not the
--- individual files it wrote. Instead this walks every node's OWN stored
--- result (`Pipeline._graph.nodes[id].result`, set by
--- `Graph:set_node_result` for every node as it runs) for hy_chunk assets.
--- Their `output_path` is still correct there: the directory sink mutates
--- `asset.output_path` on the SAME Lua table it received as input (see
--- ballad's `write_asset_to_directory`), and every plugin from
--- client.bundle onward (minify, site.manifest, the sink itself) passes
--- that same asset object through rather than copying it, so the mutation
--- is visible from any node that ever held a reference to it -- including
--- the one that created it.
--- @param p Pipeline From build_runner.load.
--- @return table[] chunks { output_path = string, virtual_path = string }
function M.collect_chunks(p)
  local chunks, seen = {}, {}
  for _, node in pairs(p._graph.nodes) do
    local assets = node.result and node.result.assets
    for _, asset in ipairs(assets or {}) do
      if asset.kind == M.VERIFIABLE_KIND and asset.output_path and not seen[asset.output_path] then
        seen[asset.output_path] = true
        chunks[#chunks + 1] = { output_path = asset.output_path, virtual_path = asset.virtual_path }
      end
    end
  end
  table.sort(chunks, function(a, b) return a.output_path < b.output_path end)
  return chunks
end

--- @param chunk_path string
--- @param harness_path string
--- @return boolean ok
--- @return string output combined stdout+stderr of the child process
local function run_isolated(chunk_path, harness_path)
  local quote = function(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
  -- `env -u` (not e.g. `LUA_PATH= luajit ...`, which sets it to an EMPTY
  -- string -- Lua then falls back to its compiled-in default, same as
  -- unset, but only by accident of that particular fallback rule) clears
  -- the variable outright, so this does not quietly depend on that rule.
  local cmd = "env -u LUA_PATH -u LUA_CPATH luajit " .. quote(harness_path) .. " " .. quote(chunk_path)
    .. " 2>&1"
  local proc = io.popen(cmd, "r")
  if not proc then
    return false, "could not spawn isolated verification process"
  end
  local output = proc:read("*a") or ""
  proc:close()
  -- NOT derived from proc:close()'s own return value: verified for real,
  -- LuaJIT's io.popen close() reports `true` here even for a child that
  -- exited 1 (io.popen wraps a plain pipe, not popen2/wait4 -- there is no
  -- portable exit-status plumbing through it in LuaJIT the way there is in
  -- PUC Lua 5.2+). The harness's own OK:/ERROR: prefix on its combined
  -- stdout+stderr is the actual signal, and is exactly the kind of thing
  -- this whole task is about not getting wrong silently.
  local ok = output:sub(1, 3) == "OK:"
  return ok, output
end

--- @param p Pipeline From build_runner.load (must have already executed).
--- @return boolean ok
--- @return table[] failures { chunk = table, output = string }
--- @return integer checked how many chunks were actually run
function M.verify(p)
  local chunks = M.collect_chunks(p)
  if #chunks == 0 then
    return true, {}, 0
  end

  local harness_path = os.tmpname()
  -- NOT the builtin `assert(io.open(...))` idiom: a caller (e.g. this
  -- module's own tests/runner.lua) may have replaced the GLOBAL `assert`
  -- with something else entirely (tests/runner.lua does exactly this, with
  -- an assertion-library TABLE, so calling it as a function raises "attempt
  -- to call a table value" instead of this module's own, real error).
  local hf, open_err = io.open(harness_path, "w")
  if not hf then
    error("hydronium build_verify: could not write isolation harness to " .. harness_path .. ": " .. tostring(open_err), 0)
  end
  hf:write(HARNESS)
  hf:close()

  local failures = {}
  for _, chunk in ipairs(chunks) do
    local ok, output = run_isolated(chunk.output_path, harness_path)
    if not ok then
      failures[#failures + 1] = { chunk = chunk, output = output }
    end
  end
  os.remove(harness_path)

  return #failures == 0, failures, #chunks
end

return M
