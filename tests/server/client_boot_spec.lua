local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local H = require("hydronium")
local server = require("hydronium_dom.server")
local island = require("hydronium_dom.server.island")
local client_boot = require("hydronium_dom.server.client_boot")
local json = require("hydronium_dom.server.json")

package.preload["spec.island_counter"] = function()
  return function(props)
    return function() return H.h("button", nil, "count " .. tostring(props.start)) end
  end
end
package.preload["spec.island_other"] = function()
  return function() return function() return H.h("span", nil, "other") end end
end

local function with_manifest(chunks, fn)
  local dir = os.tmpname() .. "-client"
  os.execute("mkdir -p '" .. dir .. "'")
  local file = io.open(dir .. "/hydronium-manifest.lua", "w")
  if not file then error("cannot write test manifest in " .. dir) end
  local rows = {}
  for _, chunk in ipairs(chunks) do
    rows[#rows + 1] = string.format("{ url = %q%s }", chunk.url, chunk.entry and string.format(", entry = %q", chunk.entry) or "")
  end
  file:write("return { chunks = { " .. table.concat(rows, ", ") .. " } }")
  file:close()
  local previous = client_boot.CLIENT_DIR
  client_boot.CLIENT_DIR = dir
  client_boot.reset()
  local ok, err = pcall(fn)
  client_boot.CLIENT_DIR = previous
  client_boot.reset()
  os.execute("rm -rf '" .. dir .. "'")
  if not ok then error(err, 0) end
end

local function boot_json(html)
  local body = html:match('<script id="__HYDRONIUM_BOOT__" type="application/json">(.-)</script>')
  return body and json.decode(body)
end

describe("hydronium_dom.server.island", function()
  it("renders the module's component in place and records module, props and priority", function()
    local html, plan = server.render_to_string(island("spec.island_counter", { start = 3 }, { hydrate = "visible" }))
    assert.truthy(html:find("<!--hy:i:hy:i1:lua--><button>count 3</button><!--hy:/i:hy:i1-->", 1, true))
    assert.equal(#plan.islands, 1)
    assert.equal(plan.islands[1].module, "spec.island_counter")
    assert.equal(plan.islands[1].props.start, 3)
    assert.equal(plan.islands[1].hydrate, "visible")
    assert.equal(plan.islands[1].props.children, nil)
  end)

  it("island.component is a drop-in component that forwards its props as island props", function()
    local Counter = island.component("spec.island_counter", { hydrate = "idle" })
    local html, plan = server.render_to_string(H.h(Counter, { start = 7 }))
    assert.truthy(html:find("<button>count 7</button>", 1, true))
    assert.equal(plan.islands[1].hydrate, "idle")
    assert.equal(plan.islands[1].props.start, 7)
    assert.equal(plan.islands[1].props.children, nil)
    local ok = pcall(server.render_to_string, H.h(Counter, { start = 1 }, H.h("i", nil, "child")))
    assert.falsy(ok)
  end)

  it("refuses props that cannot cross into the client plan", function()
    local ok, err = pcall(island, "spec.island_counter", { label = function() end })
    assert.falsy(ok)
    assert.truthy(tostring(err):find("props.label is a function", 1, true))
  end)
end)

describe("hydronium_dom.server.client_boot", function()
  local split = {
    { url = "/runtime-aaaa.lua" },
    { url = "/entry-counter-bbbb.lua", entry = "spec.island_counter" },
    { url = "/entry-other-cccc.lua", entry = "spec.island_other" },
  }

  it("emits nothing for a page without Lua islands -- no engine, no chunks", function()
    with_manifest(split, function()
      local html = server.render_to_string(H.h("main", nil, H.h("p", nil, "static"), H.h(client_boot.ClientBoot)))
      assert.equal(html, "<main><p>static</p></main>")
    end)
  end)

  it("lists the shared runtime and only the chunks of islands this page rendered", function()
    with_manifest(split, function()
      local html = server.render_to_string(H.h("main", nil,
        island("spec.island_counter", { start = 1 }),
        island("spec.island_counter", { start = 2 }),
        H.h(client_boot.ClientBoot)))
      local boot = boot_json(html)
      assert.truthy(boot)
      assert.equal(boot.hmr, false)
      assert.equal(#boot.chunks, 2)
      assert.equal(boot.chunks[1], "/__hydronium/client/runtime-aaaa.lua")
      assert.equal(boot.chunks[2], "/__hydronium/client/entry-counter-bbbb.lua")
      assert.falsy(html:find("entry-other", 1, true))
      assert.truthy(html:find('rel="modulepreload" href="/js/bootstrap/islands.js"', 1, true)
        or html:find('href="/js/bootstrap/islands.js" rel="modulepreload"', 1, true))
      assert.truthy(html:find("engine.wasm", 1, true))
    end)
  end)

  it("preloads only islands.js and its imports when every island waits for idle or visibility", function()
    with_manifest(split, function()
      local html = server.render_to_string(H.h("main", nil,
        island("spec.island_counter", { start = 1 }, { hydrate = "visible" }), H.h(client_boot.ClientBoot)))
      assert.equal(#boot_json(html).chunks, 2)
      local _, preloads = html:gsub('rel="modulepreload"', "")
      assert.equal(preloads, #client_boot.ISLAND_MODULES)
      assert.truthy(html:find("/js/bootstrap/islands.js", 1, true))
      assert.falsy(html:find("mount.js", 1, true))
      assert.falsy(html:find("engine.wasm", 1, true))
      assert.falsy(html:find('rel="preload"', 1, true))
    end)
  end)

  it("preloads the chunks of load islands only, while the boot list keeps every island's", function()
    with_manifest(split, function()
      local html = server.render_to_string(H.h("main", nil,
        island("spec.island_counter", { start = 1 }),
        island("spec.island_other", nil, { hydrate = "visible" }),
        H.h(client_boot.ClientBoot)))
      local boot = boot_json(html)
      assert.equal(#boot.chunks, 3)
      assert.equal(boot.chunks[3], "/__hydronium/client/entry-other-cccc.lua")
      assert.truthy(html:find("mount.js", 1, true))
      assert.truthy(html:find("engine.wasm", 1, true))
      local head = html:gsub('<script id="__HYDRONIUM_BOOT__".-</script>', "")
      assert.truthy(head:find("entry-counter-bbbb.lua", 1, true))
      assert.falsy(head:find("entry-other-cccc.lua", 1, true))
    end)
  end)

  it("loads a single-chunk bundle whole", function()
    with_manifest({ { url = "/runtime-dddd.lua", entry = "views.App" } }, function()
      local html = server.render_to_string(H.h("main", nil, island("spec.island_other"), H.h(client_boot.ClientBoot)))
      assert.equal(boot_json(html).chunks[1], "/__hydronium/client/runtime-dddd.lua")
    end)
  end)

  it("ignores a built bundle when told the server is not serving it (development)", function()
    with_manifest(split, function()
      local html = server.render_to_string(H.h("main", nil, island("spec.island_counter", { start = 1 }),
        H.h(client_boot.ClientBoot, { bundle = false })))
      assert.equal(boot_json(html), nil)
    end)
  end)

  it("leaves development pages (no bundle) to the live module manifest", function()
    with_manifest({}, function()
      local html = server.render_to_string(H.h("main", nil, island("spec.island_other"), H.h(client_boot.ClientBoot)))
      assert.equal(boot_json(html), nil)
    end)
  end)
end)
