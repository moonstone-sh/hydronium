local h = require("tests.runner")
local json = require("hydronium_dom.server.json")

local describe, it = h.describe, h.it
local assert = h.assert

-- examples/meteorite_ssr serves framework modules to the browser by an
-- explicit list (client_mount_demo/client_manifest.json, used by its
-- /client-mount-demo and /dual-hmr pages). A module added to core or dom and
-- required by a listed one must be listed too, or those pages fail to mount
-- (CI's dual-HMR gate then times out waiting for the Lua island).
describe("examples/meteorite_ssr client manifest", function()
  it("lists every framework module its listed modules require", function()
    local f = io.open("examples/meteorite_ssr/client_mount_demo/client_manifest.json", "rb")
    assert.truthy(f, "manifest not found")
    local manifest = json.decode(f:read("*a"))
    f:close()
    local roots = { hydronium = "core/src/", hydronium_dom = "dom/src/" }
    local missing = {}
    for id, path in pairs(manifest) do
      local root = roots[path:match("^([%w_]+)/")]
      local source = root and io.open(root .. path, "rb")
      if source then
        local text = source:read("*a")
        source:close()
        for dep in text:gmatch('require%(%s*"([%w_%.]+)"%s*%)') do
          if roots[dep:match("^([%w_]+)")] and manifest[dep] == nil then
            missing[#missing + 1] = id .. " requires " .. dep
          end
        end
      end
    end
    table.sort(missing)
    assert.equal(#missing, 0, table.concat(missing, "\n"))
  end)
end)
