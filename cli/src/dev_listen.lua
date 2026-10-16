--[[
  hydronium-cli dev_listen -- the address `meteorite dev` really listens on,
  turned into the URLs the `hydronium dev` banner prints.

  Meteorite's dev `startup` event carries no address. The generated graph
  does: `meteorite dev` writes `<graph>/listen.zon` (host, port and the
  optional `host_env`/`port_env` names the server reads at start-up, see
  meteorite's zig/main.zig applyListenEnv), and Meteorite's own dev loop
  reads the same file to find its port. The server inherits this
  process's environment, so applying the named variables here gives the
  address the server actually bound.

  A wildcard host (0.0.0.0, ::) listens on every interface: the banner then
  shows a localhost URL plus one "Network" URL per LAN IPv4 address, the way
  Vite reports `--host`.

  Everything but `read_file`/`capture` defaults is pure, so the specs drive
  it with literal strings.
--]]

local M = {}

--- Default graph directory of `meteorite dev` (its cli/dev.lua `output`).
M.DEFAULT_GRAPH_DIR = ".meteorite/graph/current"

--- @param text string|nil Contents of listen.zon.
--- @return table|nil { host?: string, port?: integer, host_env?: string, port_env?: string }
function M.parse_zon(text)
  if type(text) ~= "string" then return nil end
  local listen = {
    host = text:match('%.host%s*=%s*"([^"]*)"'),
    port = tonumber(text:match("%.port%s*=%s*(%d+)")),
    host_env = text:match('%.host_env%s*=%s*"([%a_][%w_]*)"'),
    port_env = text:match('%.port_env%s*=%s*"([%a_][%w_]*)"'),
  }
  if not listen.port then return nil end
  return listen
end

--- Applies the opted-in environment overrides exactly like the server does:
--- a numeric `port_env` value replaces the port, a non-empty `host_env`
--- value replaces the host.
--- @param listen table From M.parse_zon.
--- @param getenv fun(name: string): string|nil
--- @return table { host: string, port: integer }
function M.apply_env(listen, getenv)
  local host, port = listen.host or "127.0.0.1", listen.port
  if listen.port_env then
    local raw = getenv(listen.port_env)
    if raw and raw:match("^%d+$") then port = tonumber(raw) end
  end
  if listen.host_env then
    local raw = getenv(listen.host_env)
    if raw and raw ~= "" then host = raw end
  end
  return { host = host, port = port }
end

--- @param host string
--- @return boolean
function M.is_wildcard(host)
  return host == "0.0.0.0" or host == "::" or host == "[::]" or host == ""
end

--- Non-loopback IPv4 addresses from `ifconfig` / `ip -4 addr` output (both
--- print `inet a.b.c.d`), in order, without duplicates.
--- @param text string|nil
--- @return string[]
function M.parse_lan_addresses(text)
  local out, seen = {}, {}
  for address in (text or ""):gmatch("inet%s+(%d+%.%d+%.%d+%.%d+)") do
    if not address:match("^127%.") and not address:match("^169%.254%.") and not seen[address] then
      seen[address] = true
      out[#out + 1] = address
    end
  end
  return out
end

--- @param host string
--- @param port integer
local function url(host, port)
  if host:find(":", 1, true) and not host:match("^%[") then host = "[" .. host .. "]" end
  return "http://" .. host .. ":" .. tostring(port) .. "/"
end

--- @param address table { host: string, port: integer }
--- @param lan string[] From M.parse_lan_addresses; only used for a wildcard host.
--- @return table { url: string, network: string[] }
function M.urls(address, lan)
  if M.is_wildcard(address.host) then
    local network = {}
    for _, ip in ipairs(lan or {}) do network[#network + 1] = url(ip, address.port) end
    return { url = url("localhost", address.port), network = network }
  end
  return { url = url(address.host, address.port), network = {} }
end

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

local function capture(command)
  local pipe = io.popen(command)
  if not pipe then return nil end
  local text = pipe:read("*a")
  pipe:close()
  return text
end

--- Reads the graph's listen.zon and resolves it to banner URLs.
--- @param opts? { graph_dir?: string, getenv?: function, read_file?: function, capture?: function }
--- @return table|nil { url: string, network: string[] } nil when there is no graph yet.
function M.resolve(opts)
  opts = opts or {}
  local listen = M.parse_zon((opts.read_file or read_file)((opts.graph_dir or M.DEFAULT_GRAPH_DIR) .. "/listen.zon"))
  if not listen then return nil end
  local address = M.apply_env(listen, opts.getenv or os.getenv)
  local lan = {}
  if M.is_wildcard(address.host) then
    lan = M.parse_lan_addresses((opts.capture or capture)("(ifconfig || ip -4 addr) 2>/dev/null"))
  end
  return M.urls(address, lan)
end

return M
