--[=[
  create.update_check -- is a newer hydronium/create published than the one
  running? Feeds the wizard header's right-aligned status.

  NEVER BLOCKS. The registry index is cached for `TTL_SECONDS`; a stale or
  missing cache is refreshed by a detached `curl`. Two entry points:
    start(v)  -- for the wizard: a handle whose poll() reports "checking"
                 while the background fetch runs, then the live answer.
    check(v)  -- one-shot, cache-only: answers from the previous fetch and
                 refreshes for next time (no waiting at all).
  Nothing is ever claimed without real registry data behind it: unknown
  (offline, timed out, disabled) is nil, and the UI shows no status.

  The registry publishes every version of every package in
  `<registry>/index.toml` as `[[package]] name = ... version = ...` blocks
  (see moonstone's src/core/registry/registry.zig); that file is the source.

  Disabled (returns nil, no refresh) under CI, NO_UPDATE_NOTIFIER, or
  HYDRONIUM_NO_UPDATE_CHECK. HYDRONIUM_CREATE_REGISTRY overrides the
  registry root (useful for local registries and tests).
]=]

local M = {}

M.PACKAGE = "hydronium/create"
M.DEFAULT_REGISTRY = "https://registry.moonstone.sh/registry/v0"
M.TTL_SECONDS = 24 * 60 * 60
M.TIMEOUT_SECONDS = 5

--- Parses `X.Y.Z` (prereleases and build metadata are not candidates).
--- @param version string
--- @return integer[]|nil
function M.parse_version(version)
  local major, minor, patch = tostring(version or ""):match("^(%d+)%.(%d+)%.(%d+)$")
  if not major then return nil end
  return { tonumber(major), tonumber(minor), tonumber(patch) }
end

--- @return boolean true when version `a` is strictly newer than `b`
function M.newer(a, b)
  local pa, pb = M.parse_version(a), M.parse_version(b)
  if not pa or not pb then return false end
  for i = 1, 3 do
    if pa[i] ~= pb[i] then return pa[i] > pb[i] end
  end
  return false
end

--- Highest stable version of `package` listed in a registry index.toml.
--- @param index_text string
--- @param package? string
--- @return string|nil
function M.latest_from_index(index_text, package)
  package = package or M.PACKAGE
  local latest
  -- Each entry is its own `[[package]]` table; split on the headers so a
  -- `version` can never be attributed to a neighbouring package's `name`.
  local text = "\n" .. tostring(index_text or "")
  local blocks, start = {}, text:find("\n%[%[package%]%]")
  while start do
    local next_start = text:find("\n%[%[package%]%]", start + 1)
    blocks[#blocks + 1] = text:sub(start, (next_start or 0) - 1)
    start = next_start
  end
  for _, block in ipairs(blocks) do
    local name = block:match('\nname%s*=%s*"([^"]*)"')
    local version = block:match('\nversion%s*=%s*"([^"]*)"')
    if name == package and M.parse_version(version) and (latest == nil or M.newer(version, latest)) then
      latest = version
    end
  end
  return latest
end

local function default_getenv(name) return os.getenv(name) end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- @param getenv fun(name:string):string|nil
--- @return string
function M.cache_path(getenv)
  getenv = getenv or default_getenv
  local base = getenv("XDG_CACHE_HOME")
  if base == nil or base == "" then
    local home = getenv("HOME")
    if home == nil or home == "" then return nil end
    base = home .. "/.cache"
  end
  return base .. "/hydronium/create-registry-index.toml"
end

--- @param getenv fun(name:string):string|nil
--- @return boolean
function M.disabled(getenv)
  getenv = getenv or default_getenv
  for _, name in ipairs({ "CI", "NO_UPDATE_NOTIFIER", "HYDRONIUM_NO_UPDATE_CHECK" }) do
    local value = getenv(name)
    if value ~= nil and value ~= "" and value ~= "0" and value ~= "false" then return true end
  end
  return false
end

--- Seconds since the cache file was last written, or nil when missing.
local function cache_age(path)
  local handle = io.popen("stat -f %m " .. shell_quote(path) .. " 2>/dev/null || stat -c %Y " .. shell_quote(path) .. " 2>/dev/null")
  if not handle then return nil end
  local mtime = tonumber((handle:read("*a") or ""):match("%d+"))
  handle:close()
  if not mtime then return nil end
  return os.time() - mtime
end

--- Starts a detached background download of the index into `path`. Writes
--- to a temp file and renames, so a reader never sees a partial index. When
--- `marker` is given, the download's exit status is written there once it
--- finishes, so a caller can poll with a plain io.open instead of a fork.
function M.refresh_in_background(path, registry, execute, marker)
  execute = execute or os.execute
  local dir = path:match("^(.*)/[^/]+$")
  local tmp = path .. ".tmp"
  local command = "mkdir -p " .. shell_quote(dir)
    .. " && curl -fsSL --max-time " .. M.TIMEOUT_SECONDS
    .. " -o " .. shell_quote(tmp) .. " " .. shell_quote(registry .. "/index.toml")
    .. " && mv " .. shell_quote(tmp) .. " " .. shell_quote(path)
  if marker then
    command = "(" .. command .. "); echo $? > " .. shell_quote(marker)
  end
  return execute("(" .. command .. ") >/dev/null 2>&1 </dev/null &")
end

local function default_read_file(p)
  local file = io.open(p, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

local function registry_root(getenv)
  local registry = getenv("HYDRONIUM_CREATE_REGISTRY")
  if registry == nil or registry == "" then registry = M.DEFAULT_REGISTRY end
  return (registry:gsub("/+$", ""))
end

local function status_from(index_text, current_version)
  local latest = M.latest_from_index(index_text)
  if not latest then return nil end
  return { state = M.newer(latest, current_version) and "available" or "current", latest = latest }
end

--- Live check for an interactive UI. Returns a handle whose `poll()` gives
--- `{ state = "checking" }` while a background fetch runs, then
--- `{ state = "available"|"current", latest = "X.Y.Z" }`, or nil when the
--- answer is unknown (disabled, offline, timed out with no cache). A fresh
--- cache answers immediately with no network at all. `poll()` never blocks.
--- @param current_version string
--- @param opts? { getenv?: fun(name:string):string|nil, execute?: fun(cmd:string):any, read_file?: fun(path:string):string|nil, remove?: fun(path:string), age?: fun(path:string):number|nil, now?: fun():number }
function M.start(current_version, opts)
  opts = opts or {}
  local getenv = opts.getenv or default_getenv
  local read_file = opts.read_file or default_read_file
  local remove = opts.remove or os.remove
  local now = opts.now or os.time
  local path = not M.disabled(getenv) and M.cache_path(getenv) or nil
  if not path then return { poll = function() return nil end } end

  local age = (opts.age or cache_age)(path)
  if age ~= nil and age <= M.TTL_SECONDS then
    local status = status_from(read_file(path), current_version)
    return { poll = function() return status end }
  end

  local marker = path .. ".done." .. tostring(now()) .. "." .. tostring(math.random(1e6))
  local started = now()
  local launched = pcall(M.refresh_in_background, path, registry_root(getenv), opts.execute, marker)
  local result, finished = nil, not launched
  -- A failed or timed-out fetch falls back to whatever (stale) cache exists.
  local function settle()
    finished = true
    result = status_from(read_file(path), current_version)
  end
  if not launched then settle() end

  return {
    poll = function()
      if finished then return result end
      local code = read_file(marker)
      if code and code:match("%d") then
        pcall(remove, marker)
        settle()
        return result
      end
      if now() - started > M.TIMEOUT_SECONDS + 2 then
        settle()
        return result
      end
      return { state = "checking" }
    end,
  }
end

--- @param current_version string
--- @param opts? { getenv?: fun(name:string):string|nil, execute?: fun(cmd:string):any, read_file?: fun(path:string):string|nil, age?: fun(path:string):number|nil }
--- @return { available: boolean, latest: string }|nil nil when unknown
function M.check(current_version, opts)
  opts = opts or {}
  local getenv = opts.getenv or default_getenv
  if M.disabled(getenv) then return nil end
  local path = M.cache_path(getenv)
  if not path then return nil end

  local age = (opts.age or cache_age)(path)
  if age == nil or age > M.TTL_SECONDS then
    pcall(M.refresh_in_background, path, registry_root(getenv), opts.execute)
  end
  if age == nil then return nil end

  local status = status_from((opts.read_file or default_read_file)(path), current_version)
  if status then status.available = status.state == "available" end
  return status
end

return M
