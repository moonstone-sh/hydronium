local h = require("tests.runner")
local describe, it, after_each = h.describe, h.it, h.after_each
local assert = h.assert

local interpreter = require("hydronium.interpreter.lua")

local BRIDGE_GLOBALS = { "hy_find_island", "hy_query_button", "hy_get_text", "hy_set_text", "hy_on_click" }

--- Installs a fake DOM (plain Lua tables) as the hy_* bridge globals
--- `hydronium.interpreter.lua` expects its host to provide. Real DOM
--- behavior (TreeWalker over comment nodes, real dispatched click
--- events) is verified separately, against a real DOM implementation
--- (jsdom) and against a real WASM Lua runtime (wasmoon) -- see the
--- published "Hydronium in WASM" proof and
--- docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md. This spec exists to pin the
--- module's own Lua-side contract and diagnostics under LuaJIT, fast,
--- without a browser or WASM in the loop.
local function install_fake_dom(island_id)
  local button = { text = "", click_handlers = {} }
  local island = { button = button }
  _G.hy_find_island = function(id) return (id == island_id) and island or nil end
  _G.hy_query_button = function(isl) return isl.button end
  _G.hy_get_text = function(btn) return btn.text end
  _G.hy_set_text = function(btn, text) btn.text = text end
  _G.hy_on_click = function(btn, cb) table.insert(btn.click_handlers, cb) end
  return button
end

local function fire_click(button)
  for _, cb in ipairs(button.click_handlers) do cb() end
end

describe("hydronium.interpreter.lua (client Lua runtime for d.lua.island)", function()
  -- These tests install their DOM bridge as plain globals (matching the
  -- real contract hydronium/interpreter/lua.lua documents -- a real host
  -- would set these once via lua.global.set, not per-test). Cleaning them
  -- up here is required, not cosmetic: leaving them in _G would trip
  -- tests/luax/isolation_spec.lua's global-namespace-pollution check for
  -- any spec file that happens to run after this one.
  after_each(function()
    for _, name in ipairs(BRIDGE_GLOBALS) do
      _G[name] = nil
    end
  end)

  it("renders the initial count via a real createEffect immediately on hydration", function()
    local button = install_fake_dom("hy:i1")
    interpreter.hydrate_counter_island("hy:i1", 10)
    assert.equal(button.text, "Count: 10")
  end)

  it("returns a handle whose :get() reflects the real underlying signal", function()
    install_fake_dom("hy:i1")
    local counter = interpreter.hydrate_counter_island("hy:i1", 5)
    assert.equal(counter.get(), 5)
  end)

  it("registers exactly one click handler on the real button node", function()
    local button = install_fake_dom("hy:i1")
    interpreter.hydrate_counter_island("hy:i1", 0)
    assert.equal(#button.click_handlers, 1)
  end)

  it("a click increments the signal and the DOM text updates via the real effect, not a hand-called render", function()
    local button = install_fake_dom("hy:i1")
    local counter = interpreter.hydrate_counter_island("hy:i1", 10)
    fire_click(button)
    assert.equal(counter.get(), 11)
    assert.equal(button.text, "Count: 11")
  end)

  it("multiple clicks accumulate correctly", function()
    local button = install_fake_dom("hy:i1")
    local counter = interpreter.hydrate_counter_island("hy:i1", 0)
    fire_click(button)
    fire_click(button)
    fire_click(button)
    assert.equal(counter.get(), 3)
    assert.equal(button.text, "Count: 3")
  end)

  it("raises a clear, distinct diagnostic when the island DOM does not exist, instead of a raw nil-index error", function()
    _G.hy_find_island = function() return nil end
    local ok, err = pcall(interpreter.hydrate_counter_island, "hy:does-not-exist", 0)
    assert.falsy(ok)
    assert.truthy(tostring(err):find("no DOM found for island", 1, true))
    assert.truthy(tostring(err):find("hy:does%-not%-exist"))
  end)

  it("raises a clear, distinct diagnostic when the island has no <button>", function()
    _G.hy_find_island = function() return {} end
    _G.hy_query_button = function() return nil end
    local ok, err = pcall(interpreter.hydrate_counter_island, "hy:i2", 0)
    assert.falsy(ok)
    assert.truthy(tostring(err):find("no <button> to hydrate", 1, true))
  end)
end)
