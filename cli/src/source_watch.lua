--[[
  hydronium-cli source_watch -- keeps Ballad's source inventory current
  during `hydronium dev --watch-sources`.

  Discovery itself is a Ballad node (`hydronium_ballad.source_inventory`,
  run by `ballad play`). This module only decides WHEN to re-run it: when a
  `.lua`/`.luax` file appears or disappears under a root declared in
  `hydronium.sources.lua`, or that file itself changes. Content edits to an
  existing module never change the inventory (paths and topology only), so
  they cost nothing here; HMR handles them.

  Polled from the dev UI's own tick rather than a separate watcher process:
  there is no second long-lived child to supervise or orphan, and a Ballad
  run for the inventory takes a fraction of a second.
--]]

local topology = require("hydronium.core.source_topology")

local M = {}

M.CONFIG_PATH = "hydronium.sources.lua"
M.INTERVAL_MS = 750

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function shell_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- One string that changes exactly when the inventory would: the config's
--- bytes plus the sorted `.lua`/`.luax` paths under every declared root.
--- @param opts? { config_path?: string, popen?: function }
--- @return string|nil snapshot, string|nil err
function M.snapshot(opts)
  opts = opts or {}
  local config_path = opts.config_path or M.CONFIG_PATH
  local content = read(config_path)
  if not content then return nil, "cannot read " .. config_path end
  local chunk, load_err = (loadstring or load)(content, "@" .. config_path)
  if not chunk then return nil, load_err end
  local ok, config = pcall(chunk)
  if not ok or type(config) ~= "table" then return nil, config_path .. " must return a table" end
  local roots_ok, roots = pcall(topology.scan_roots, config)
  if not roots_ok then return nil, tostring(roots) end

  local popen = opts.popen or io.popen
  local paths = {}
  for _, dir in ipairs(roots) do
    local process = popen("find " .. shell_quote(dir)
      .. " -type f \\( -name '*.lua' -o -name '*.luax' \\) 2>/dev/null", "r")
    if process then
      for path in process:lines() do paths[#paths + 1] = path end
      process:close()
    end
  end
  table.sort(paths)
  return content .. "\0" .. table.concat(paths, "\n")
end

--- @param opts { run: fun(): boolean, config_path?: string, popen?: function, interval_ms?: integer }
function M.new(opts)
  local watcher = {
    run = opts.run,
    config_path = opts.config_path,
    popen = opts.popen,
    interval_ms = opts.interval_ms or M.INTERVAL_MS,
    last_poll = nil,
    last = nil,
  }

  --- Record the current state without running (the caller just ran Ballad).
  function watcher:prime()
    self.last = M.snapshot({ config_path = self.config_path, popen = self.popen })
  end

  --- @param now_ms integer
  --- @return table|nil result `{ ok = boolean }` when a re-run happened
  function watcher:poll(now_ms)
    if self.last_poll and now_ms - self.last_poll < self.interval_ms then return nil end
    self.last_poll = now_ms
    local current = M.snapshot({ config_path = self.config_path, popen = self.popen })
    if current == nil or current == self.last then return nil end
    self.last = current
    return { ok = self.run() }
  end

  return watcher
end

return M
