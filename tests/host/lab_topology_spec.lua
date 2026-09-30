--[[
  Lab resolves project modules through the same source topology as the app's
  dev host (hydronium.sources.lua / Ballad inventory), and serves the DOM
  client runtime by structure rather than a hand-kept file list.
--]]
local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
package.path = "meteorite/src/?.lua;meteorite/src/?/init.lua;" .. package.path

local function write(path, content)
  local f = io.open(path, "w")
  f:write(content)
  f:close()
end

describe("Lab and the project source topology", function()
  it("bundles a story's namespaced import that module_roots alone cannot resolve", function()
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "/src/components' '" .. dir .. "/stories'")
    write(dir .. "/hydronium.sources.lua", [[return {
  files = { "src/components/Button.luax" },
  roots = { { path = "src/components", namespace = "ui", target = "client" } },
}]])
    write(dir .. "/src/components/Button.luax", 'local H = require("hydronium")\nreturn function() return H.h("button", nil, "ok") end\n')
    write(dir .. "/stories/Button.stories.lua", 'local Button = require("ui.Button")\nreturn { renderer = "dom", render = Button }\n')
    local script = dir .. "/probe.lua"
    write(script, table.concat({
      "package.path = " .. string.format("%q", package.path),
      'local dom_lab = require("hydronium_meteorite.dom_lab")',
      'local config = { paths = { "stories/Button.stories.lua" }, roots = { "stories" }, module_roots = { "src" } }',
      'local registry = { stories = { { renderer = "dom", source = { path = "stories/Button.stories.lua" } } } }',
      "local sources, project = dom_lab.sources(config, registry)",
      'io.write(project["ui.Button"] and sources["ui.Button"] and "resolved" or "missing")',
    }, "\n"))
    local cwd = io.popen("pwd"):read("*l")
    local abs = {}
    for entry in package.path:gmatch("[^;]+") do
      abs[#abs + 1] = entry:sub(1, 1) == "/" and entry or (cwd .. "/" .. entry)
    end
    write(script, (io.open(script):read("*a"):gsub("package%.path = [^\n]+", "package.path = " .. string.format("%q", table.concat(abs, ";")))))
    local out = io.popen("cd '" .. dir .. "' && luajit probe.lua 2>&1"):read("*a")
    os.execute("rm -rf '" .. dir .. "'")
    assert.equal(out, "resolved")
  end)

  it("serves DOM client runtime files by structure, never by traversal", function()
    local host = require("hydronium_meteorite.lab")
    assert.truthy(host.dom_client_file("mount.js"))
    assert.truthy(host.dom_client_file("a_new_runtime_file.js"))
    assert.truthy(host.dom_client_file("vendor/wasmoon/glue.wasm"))
    assert.truthy(host.dom_client_file("vendor/wasmoon/wasmoon.esm.js"))
    assert.falsy(host.dom_client_file("../secret.js"))
    assert.falsy(host.dom_client_file("vendor/other/x.js"))
    assert.falsy(host.dom_client_file("styles.css"))
    assert.falsy(host.dom_client_file("sub/dir.js"))
  end)
end)
