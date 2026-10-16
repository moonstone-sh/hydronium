--[[
  hydronium-cli dev_listen: the `hydronium dev` banner's URLs come from the
  address the server really binds (listen.zon + its env overrides), never a
  made-up default, and a wildcard host adds LAN "Network" URLs.
--]]

local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local dev_listen = require("dev_listen")

local SITE_ZON = [[
.{
    .host = "127.0.0.1",
    .port = 6300,
    .port_env = "PORT",
}
]]

local IFCONFIG = [[
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
	inet6 ::1 prefixlen 128
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet6 fe80::1c2b:aa%en0 prefixlen 64 secured scopeid 0xb
	inet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
en5: flags=8863<UP> mtu 1500
	inet 169.254.10.2 netmask 0xffff0000
bridge100: flags=8863<UP> mtu 1500
	inet 192.168.64.1 netmask 0xffffff00 broadcast 192.168.64.255
]]

local function env(values)
  return function(name) return values[name] end
end

describe("dev_listen", function()
  it("parses listen.zon, including the opt-in env names", function()
    local listen = dev_listen.parse_zon(SITE_ZON)
    assert.equal("127.0.0.1", listen.host)
    assert.equal(6300, listen.port)
    assert.equal("PORT", listen.port_env)
    assert.is_nil(listen.host_env)
    assert.is_nil(dev_listen.parse_zon(nil))
    assert.is_nil(dev_listen.parse_zon(".{}"))
  end)

  it("applies port_env/host_env the way the server does", function()
    local listen = dev_listen.parse_zon(SITE_ZON)
    assert.equal(6412, dev_listen.apply_env(listen, env({ PORT = "6412" })).port)
    assert.equal(6300, dev_listen.apply_env(listen, env({ PORT = "nope" })).port)
    assert.equal(6300, dev_listen.apply_env(listen, env({})).port)
    local hosted = { host = "127.0.0.1", port = 8080, host_env = "HOST" }
    assert.equal("0.0.0.0", dev_listen.apply_env(hosted, env({ HOST = "0.0.0.0" })).host)
    assert.equal("127.0.0.1", dev_listen.apply_env(hosted, env({ HOST = "" })).host)
  end)

  it("lists LAN IPv4 addresses, without loopback or link-local ones", function()
    assert.same({ "192.168.1.20", "192.168.64.1" }, dev_listen.parse_lan_addresses(IFCONFIG))
    assert.same({}, dev_listen.parse_lan_addresses(nil))
  end)

  it("builds one local URL for a specific host", function()
    local urls = dev_listen.urls({ host = "127.0.0.1", port = 6300 }, { "192.168.1.20" })
    assert.equal("http://127.0.0.1:6300/", urls.url)
    assert.same({}, urls.network)
    assert.equal("http://[::1]:6300/", dev_listen.urls({ host = "::1", port = 6300 }).url)
  end)

  it("adds Network URLs for a wildcard host", function()
    local urls = dev_listen.urls({ host = "0.0.0.0", port = 6412 }, { "192.168.1.20" })
    assert.equal("http://localhost:6412/", urls.url)
    assert.same({ "http://192.168.1.20:6412/" }, urls.network)
  end)

  it("resolves from the graph directory and the environment", function()
    local zon = '.{ .host = "0.0.0.0", .port = 6300, .port_env = "PORT" }'
    local read = {}
    local urls = dev_listen.resolve({
      graph_dir = "g",
      read_file = function(path) read[#read + 1] = path; return zon end,
      getenv = env({ PORT = "6412" }),
      capture = function() return IFCONFIG end,
    })
    assert.same({ "g/listen.zon" }, read)
    assert.equal("http://localhost:6412/", urls.url)
    assert.same({ "http://192.168.1.20:6412/", "http://192.168.64.1:6412/" }, urls.network)
    assert.is_nil(dev_listen.resolve({ read_file = function() return nil end }))
  end)
end)

describe("hydronium_cli.ui.app -- banner URL", function()
  local hydronium = require("hydronium")
  local session = require("hydronium_ink.session")
  local ui = require("ui.app")

  local function paint(state)
    local out = {}
    local s = session.create(hydronium.h(ui.create_app(state, {})),
      { writeFn = function(b) out[#out + 1] = b end, columns = 100, rows = 20 })
    s:step()
    s:close()
    return (table.concat(out):gsub("\27%[[%d;?]*[a-zA-Z]", ""):gsub("\27%][^\27]*\27\\", ""))
  end

  it("prints no made-up URL when the address is unknown", function()
    assert.is_nil(ui.DEFAULT_URL)
    local state = ui.new_state({})
    state:apply({ kind = "startup", routes = 3, ready_ms = 100 })
    local text = paint(state)
    assert.truthy(text:find("Hydronium app up and running", 1, true), text)
    assert.falsy(text:find("8080", 1, true), text)
  end)

  it("prints the resolved URL and the Network URLs", function()
    local state = ui.new_state({})
    state:apply({ kind = "startup", routes = 3, ready_ms = 100 })
    state.set_url("http://localhost:6412/")
    state.set_network_urls({ "http://192.168.1.20:6412/" })
    local text = paint(state)
    assert.truthy(text:find("up and running on http://localhost:6412/", 1, true), text)
    assert.truthy(text:find("Network: http://192.168.1.20:6412/", 1, true), text)
  end)
end)
