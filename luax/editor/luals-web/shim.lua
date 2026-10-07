-- lua-language-server without an OS: an in-memory filesystem, `io.open` and
-- `require` over it, Lua stand-ins for the bee.* C modules, and an inline
-- `pub`/`brave` (LuaLS's worker threads) that runs worker tasks in place.
-- The same file runs natively (spike) and in the browser engine.
local M = {}

---------------------------------------------------------------- vfs
local files, children = {}, { ["/"] = {} }

local function norm(p)
  p = tostring(p):gsub("\\", "/")
  if p:sub(1, 1) ~= "/" then p = "/" .. p end
  local out = {}
  for part in p:gmatch("[^/]+") do
    if part == ".." then out[#out] = nil
    elseif part ~= "." then out[#out + 1] = part end
  end
  return "/" .. table.concat(out, "/")
end
local function parent(p) return p:match("^(.*)/[^/]*$") ~= "" and p:match("^(.*)/[^/]*$") or "/" end
local function base(p) return p:match("([^/]*)$") end

local function mkdirs(p)
  p = norm(p)
  if children[p] then return end
  if p ~= "/" then
    local up = parent(p)
    mkdirs(up)
    children[up][base(p)] = "directory"
  end
  children[p] = children[p] or {}
end
local function write(p, content)
  p = norm(p)
  mkdirs(parent(p))
  children[parent(p)][base(p)] = "regular"
  files[p] = content
end
local function remove(p)
  p = norm(p)
  if files[p] then files[p] = nil
  elseif children[p] then
    for name in pairs(children[p]) do remove(p .. "/" .. name) end
    children[p] = nil
  else return false end
  local up = children[parent(p)]
  if up then up[base(p)] = nil end
  return true
end
M.vfs = { norm = norm, write = write, read = function(p) return files[norm(p)] end, mkdirs = mkdirs, remove = remove,
  exists = function(p) p = norm(p); return files[p] ~= nil or children[p] ~= nil end,
  isdir = function(p) return children[norm(p)] ~= nil end, list = function(p) return children[norm(p)] end }

---------------------------------------------------------------- io over the vfs
local File = {}
File.__index = File
function File:read(...)
  local out = {}
  local fmts = select("#", ...) == 0 and { "l" } or { ... }
  for i, fmt in ipairs(fmts) do
    local f = type(fmt) == "string" and fmt:gsub("^%*", "") or fmt
    local data = self.data
    if type(f) == "number" then
      if self.pos > #data then out[i] = nil else out[i] = data:sub(self.pos, self.pos + f - 1); self.pos = self.pos + f end
    elseif f:sub(1, 1) == "a" then out[i] = data:sub(self.pos); self.pos = #data + 1
    elseif f:sub(1, 1) == "l" or f:sub(1, 1) == "L" then
      if self.pos > #data then out[i] = nil else
        local e = data:find("\n", self.pos, true)
        local line = data:sub(self.pos, e and (f:sub(1, 1) == "L" and e or e - 1) or #data)
        self.pos = e and e + 1 or #data + 1
        out[i] = line
      end
    elseif f:sub(1, 1) == "n" then
      local s, e = data:find("^%s*[-+]?%d+%.?%d*[eE]?[-+]?%d*", self.pos)
      if s then out[i] = tonumber(data:sub(s, e)); self.pos = e + 1 else out[i] = nil end
    end
  end
  return table.unpack(out, 1, #fmts)
end
function File:lines(...) local args = { ... }; return function() return self:read(table.unpack(args)) end end
function File:write(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  files[self.path] = (files[self.path] or "") .. table.concat(parts)
  return self
end
function File:seek(whence, off)
  whence, off = whence or "cur", off or 0
  local size = #(self.data or "")
  if whence == "set" then self.pos = off + 1 elseif whence == "end" then self.pos = size + off + 1 else self.pos = self.pos + off end
  return self.pos - 1
end
function File:flush() return self end
function File:close() self:flush(); self.closed = true; return true end
function File:setvbuf() return true end

local native_io = io
M.native = { open = io.open, lines = io.lines, loadfile = loadfile, dofile = dofile }
function io.open(path, mode)
  mode = mode or "r"
  local p = norm(path)
  if mode:find("[wa]") then
    if mode:find("w") then write(p, "") end
    return setmetatable({ path = p, writing = true, append = true, buf = {}, pos = 1, data = "" }, File)
  end
  local data = files[p]
  if not data then return nil, tostring(path) .. ": No such file or directory", 2 end
  return setmetatable({ path = p, data = data, pos = 1 }, File)
end
function io.lines(path, ...)
  if not path then return native_io.read and function() return nil end end
  local f = assert(io.open(path))
  return f:lines(...)
end
function loadfile(path, mode, env)
  local data = files[norm(path)]
  if not data then return nil, "cannot open " .. tostring(path) end
  if env ~= nil then return load(data, "@" .. norm(path), mode, env) end
  return load(data, "@" .. norm(path), mode)
end
function dofile(path) return assert(loadfile(path))() end

-- `require` finds modules in the vfs through package.path.
table.insert(package.searchers, 2, function(name)
  local rel = name:gsub("%.", "/")
  local tried = {}
  for template in package.path:gmatch("[^;]+") do
    local p = norm((template:gsub("%?", rel)))
    local data = files[p]
    if data then
      local f, err = load(data, "@" .. p)
      if not f then error(err, 2) end
      return f, p
    end
    tried[#tried + 1] = "\n\tno vfs file '" .. p .. "'"
  end
  return table.concat(tried)
end)

---------------------------------------------------------------- bee.*
-- Paths are userdata, as in bee: LuaLS's fs-utility treats tables as its own
-- in-memory "dummy" paths. The string lives in a weak side table.
local Path = {}
local pathString = setmetatable({}, { __mode = "k" })
local newuserdata = assert(__luals_newuserdata, "the host must provide __luals_newuserdata")
Path.__index = function(self, key)
  if key == "s" then return pathString[self] end
  return Path[key]
end
local function P(s)
  if getmetatable(s) == Path then return s end
  s = tostring(s):gsub("\\", "/")
  if #s > 1 then s = s:gsub("/+$", "") end
  local u = newuserdata()
  debug.setmetatable(u, Path)
  pathString[u] = s
  return u
end
Path.__tostring = function(self) return pathString[self] end
Path.__div = function(a, b)
  local sa, sb = tostring(a), tostring(b)
  if sb:sub(1, 1) == "/" then return P(sb) end
  if sa == "" then return P(sb) end
  return P(sa:gsub("/$", "") .. "/" .. sb)
end
Path.__eq = function(a, b) return tostring(a) == tostring(b) end
Path.__concat = function(a, b) return tostring(a) .. tostring(b) end
function Path:string() return self.s end
function Path:generic_string() return self.s end
function Path:parent_path() local p = self.s:match("^(.*)/[^/]*$"); return P(p == "" and "/" or p or "") end
function Path:filename() return P(self.s:match("([^/]*)$")) end
function Path:stem() local f = self.s:match("([^/]*)$"); return P(f:match("^(.+)%.[^.]*$") or f) end
function Path:extension() return P(self.s:match("[^/](%.[^./]*)$") or "") end
function Path:is_absolute() return self.s:sub(1, 1) == "/" end
function Path:is_relative() return self.s:sub(1, 1) ~= "/" end
function Path:lexically_normal() return P(self.s:sub(1, 1) == "/" and norm(self.s) or self.s) end
function Path:replace_extension(ext) local s = self.s:gsub("%.[^./]*$", ""); ext = tostring(ext); return P(s .. (ext:sub(1, 1) == "." and ext or "." .. ext)) end
function Path:replace_filename(name) return self:parent_path() / name end
function Path:remove_filename() return P(self.s:gsub("[^/]*$", "")) end
function Path:has_filename() return self.s:match("[^/]$") ~= nil end
function Path:has_parent_path() return self.s:find("/", 1, true) ~= nil end

local Status = {}
Status.__index = Status
function Status:type() return self.t end
function Status:exists() return self.t ~= "not_found" end
function Status:is_directory() return self.t == "directory" end
function Status:is_regular_file() return self.t == "regular" end
local function status(p)
  p = norm(tostring(p))
  return setmetatable({ t = children[p] and "directory" or files[p] and "regular" or "not_found" }, Status)
end

local fs = {
  path = P,
  exists = function(p) return M.vfs.exists(tostring(p)) end,
  is_directory = function(p) return children[norm(tostring(p))] ~= nil end,
  is_regular_file = function(p) return files[norm(tostring(p))] ~= nil end,
  status = status, symlink_status = status,
  canonical = function(p) return P(norm(tostring(p))) end,
  absolute = function(p) return P(norm(tostring(p))) end,
  fullpath = function(p) return P(norm(tostring(p))) end,
  current_path = function() return P("/") end,
  temp_directory_path = function() return P("/tmp") end,
  create_directories = function(p) mkdirs(tostring(p)); return true end,
  create_directory = function(p) mkdirs(tostring(p)); return true end,
  remove = function(p) return remove(tostring(p)) end,
  remove_all = function(p) return remove(tostring(p)) and 1 or 0 end,
  rename = function(a, b) local d = files[norm(tostring(a))]; if d then write(tostring(b), d); remove(tostring(a)) end end,
  copy_file = function(a, b) local d = files[norm(tostring(a))]; if d then write(tostring(b), d); return true end; return false end,
  relative = function(p, b)
    local sp, sb = norm(tostring(p)), norm(tostring(b or "/"))
    if sp:sub(1, #sb + 1) == sb .. "/" then return P(sp:sub(#sb + 2)) end
    return P(sp)
  end,
  exe_path = function() return P("/luals/bin/lua-language-server") end,
  last_write_time = function() return 0 end,
  copy_options = { none = 0, skip_existing = 1, overwrite_existing = 2, update_existing = 4, recursive = 8 },
  file_type = { not_found = "not_found", regular = "regular", directory = "directory", symlink = "symlink" },
}
function fs.pairs(dir)
  local list = children[norm(tostring(dir))] or {}
  local names = {}
  for name in pairs(list) do names[#names + 1] = name end
  table.sort(names)
  local i = 0
  return function()
    i = i + 1
    local name = names[i]
    if not name then return nil end
    local full = P(dir) / name
    return full, status(full)
  end
end
fs.type = function(p) return status(p):type() end

-- Whole milliseconds, like bee.time: LuaLS's timer keys callbacks by integer
-- frame, and a fractional clock makes it skip frames it has already ticked.
M.now = __host_now or function() return math.floor(os.clock() * 1000) end
local modules = {
  ["bee.filesystem"] = fs,
  ["bee.platform"] = { os = "linux", OS = "Linux", Arch = "wasm32", CRT = "musl", Compiler = "clang" },
  ["bee.time"] = { time = function() return os.time() * 1000 end, monotonic = function() return math.floor(M.now()) end },
  ["bee.sys"] = { exe_path = function() return fs.exe_path() end, dll_path = function() return P("/luals/bin") end, fullpath = function(p) return P(norm(tostring(p))) end },
  ["bee.thread"] = { sleep = function() end, setname = function() end, id = 0, errlog = function() return nil end,
    create = function() error("bee.thread: no threads in this host") end, newchannel = function() end, channel = function() end, wait = function() end },
  ["bee.channel"] = { create = function() return { push = function() end, pop = function() return false end } end, query = function() return nil end },
  ["bee.subprocess"] = { get_id = function() return 1 end, spawn = function() return nil, "no processes" end },
  ["bee.select"] = { create = function() return { wait = function() return function() end end, event_add = function() end, event_del = function() end, close = function() end } end },
  ["bee.socket"] = { create = function() return nil, "no sockets" end, pair = function() return nil end },
  ["bee.epoll"] = { create = function() return nil end },
  ["bee.filewatch"] = { create = function() return { add = function() end, set_recursive = function() end, set_follow_symlinks = function() end, set_filter = function() end, select = function() return nil end } end },
  ["bee.windows"] = { filemode = function() end },
  -- The C++ formatter is not built in: formatting and the code-style check
  -- report nothing.
  ["code_format"] = setmetatable({}, { __index = function() return function() return false end end }),
}
for name, mod in pairs(modules) do package.preload[name] = function() return mod end end

---------------------------------------------------------------- pub / brave: tasks run in place
local brave = { ability = {}, id = 0 }
function brave.on(name, fn) brave.ability[name] = fn end
function brave.register() end
function brave.start() end
local pub = { ability = {}, braves = {}, allBraves = {}, publicBraves = {}, privateBraves = {}, publicQueue = {}, privateQueues = {}, taskMap = {} }
function brave.push(name, params)
  local fn = pub.ability[name]
  if fn then xpcall(fn, log and log.error or print, params, brave) end
end
function pub.on(name, fn) pub.ability[name] = fn end
function pub.recruitBraves() end
function pub.step() end
function pub.checkDead() end
local skip = { timer = true, loadProtoByStdio = true, loadProtoBySocket = true }
local function run(name, params)
  if skip[name] then return nil end
  local fn = brave.ability[name]
  if not fn then return nil end
  local ok, res = xpcall(fn, log and log.error or print, params)
  return ok and res or nil
end
function pub.task(name, params, callback)
  local res = run(name, params)
  if callback then xpcall(callback, log and log.error or print, res) end
end
function pub.awaitTask(name, params) return run(name, params) end
package.preload["pub.pub"] = function() return pub end
package.preload["brave.brave"] = function() return brave end
M.pub, M.brave = pub, brave

LUALS_SHIM = M
LUALS = LUALS or {}
-- Bundle: repeated `path \0 length \0 content`.
function LUALS.mount(blob)
  local i, n = 1, 0
  while i <= #blob do
    local a = blob:find("\0", i, true)
    local b = blob:find("\0", a + 1, true)
    local len = tonumber(blob:sub(a + 1, b - 1))
    write(blob:sub(i, a - 1), blob:sub(b + 1, b + len))
    i, n = b + len + 1, n + 1
  end
  return tostring(n)
end
-- One file: `path \0 content`.
function LUALS.write(data)
  local a = data:find("\0", 1, true)
  write(data:sub(1, a - 1), data:sub(a + 1))
  return ""
end
if __host_emit then
  LUALS.emit = function(text) __host_emit(1, text) end
  LUALS.log = function(level, msg) __host_emit(2, tostring(level) .. ": " .. tostring(msg)) end
end
function LUALS.boot()
  dofile("/luals/boot.lua")
  return ""
end
return M
