local runner = require("tests.runner")
package.path = "./luax/src/?.lua;./build/src/?.lua;" .. package.path
local describe, it, assert = runner.describe, runner.it, runner.assert
local graph = require("ballad.graph")
local plugin = require("hydronium_ballad.plugins.luax")

local function compile(filename, content)
  local path = (os.getenv("TMPDIR") or "/tmp") .. "/hydronium_markdown_build_" .. filename
  local file = io.open(path, "wb")
  assert.truthy(file)
  file:write(content); file:close()
  local store = graph.Graph.new()
  local input = store:add_asset({ kind = "file", source_path = path, virtual_path = "docs/" .. filename,
    metadata = { hydronium = { module_id = "docs.Intro" } } })
  local ctx = { graph = store, fail = function(message) error(message, 0) end, warn = function() end }
  local result = plugin.compile(ctx, { { assets = { input } } }, { target = "client" })
  os.remove(path)
  assert.equal(#result.assets, 1)
  return result.assets[1]
end

describe("Ballad Markdown compilation", function()
  it("turns md and mdx files into ordinary client Lua modules", function()
    local prose = compile("Intro.md", "# Hello\n")
    assert.equal(prose.kind, "hy_module")
    assert.equal(prose.virtual_path, "docs/Intro.lua")
    assert.equal(prose.metadata.hydronium.module_id, "docs.Intro")
    assert.equal(prose.metadata.hydronium.target, "client")
    assert.truthy(prose.content:find('H.h%(HydroniumMdH1'))

    local mixed = compile("Intro.mdx", "```lua setup\nlocal Demo = require('Demo')\n```\n<Demo />\n")
    assert.equal(mixed.virtual_path, "docs/Intro.lua")
    assert.truthy(mixed.content:find("require%('Demo'%)"))
    assert.truthy(mixed.content:find("H.h%(Demo"))
  end)
end)
