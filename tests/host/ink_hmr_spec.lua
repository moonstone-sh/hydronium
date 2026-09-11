local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
local H = require("hydronium")
local terminal = require("hydronium_ink.host.terminal")
local Reconciler = require("hydronium.core.reconciler").Reconciler
local family = require("hydronium.core.family")
local family_loader = require("hydronium.core.family_loader")
local hmr = require("hydronium.core.hmr")

describe("Ink component-family HMR", function()
  it("refreshes the terminal tree in the same VM without resetting state", function()
    local id = "scratch.ink_hmr_app"
    package.loaded[id] = nil
    package.preload[id] = nil
    family_loader.reset()
    family.reset()
    family_loader.enable()

    hmr.install(id, [[
      local H = require("hydronium")
      local ink = require("hydronium_ink")
      return function(_, scope)
        local count, set_count = scope.refresh_registry:signal(1, {
          kind = "signal", name = "count", block_path = "ink.app.setup",
        })
        _G.__ink_hmr_set = set_count
        return function() return ink.Text(nil, "old " .. count()) end
      end
    ]])
    local App = require(id)
    local writes = {}
    local host = terminal.createTerminalHost(function(bytes) writes[#writes + 1] = bytes end)
    local reconciler = Reconciler.new(host)
    local vnode = H.h(App)
    reconciler:mount(vnode, host.getRoot())
    host.flush()
    _G.__ink_hmr_set(6)
    host.flush()

    local result = hmr.replace(id, [[
      local H = require("hydronium")
      local ink = require("hydronium_ink")
      return function(_, scope)
        local count, set_count = scope.refresh_registry:signal(1, {
          kind = "signal", name = "count", block_path = "ink.app.setup",
        })
        _G.__ink_hmr_set = set_count
        return function() return ink.Text(nil, "new " .. count()) end
      end
    ]])
    host.flush()

    assert.equal(result.failed, 0)
    local frame = host.getLastFrame()
    local rendered = {}
    for x = 1, frame.w do rendered[#rendered + 1] = frame.rows[1][x].ch end
    assert.equal(table.concat(rendered), "new 6", "terminal frame must contain refreshed code and preserved state")

    reconciler:unmount(vnode)
    _G.__ink_hmr_set = nil
    package.loaded[id] = nil
    package.preload[id] = nil
    family_loader.reset()
    family.reset()
  end)
end)
