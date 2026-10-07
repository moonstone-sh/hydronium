local t = require("tests.runner")
local describe, it, assert = t.describe, t.it, t.assert
package.path = "./luax/src/?.lua;" .. package.path
local H, lab = require("hydronium"), require("hydronium_lab")
package.path = "meteorite/src/?.lua;meteorite/src/?/init.lua;" .. package.path

describe("DOM and mixed Lab", function()
  it("exposes workbench parts without requiring the default shell", function()
    local C = require("hydronium_lab.components")
    local server = require("hydronium_dom.server")
    local html = server.renderToString(H.h(C.Root, { project_id="custom", style="display:flex;flex-direction:column" },
      H.h(C.Sidebar, nil, H.h(C.StorySearch), H.h(C.StoryCatalog)),
      H.h(C.Canvas, nil, H.h(C.Stage, nil, H.h(C.Viewport, nil, H.h("iframe", { ["data-lab-dom-preview"]="" }))))))
    assert.truthy(html:find('data-lab-layout="custom"', 1, true))
    assert.truthy(html:find('display:flex;flex-direction:column', 1, true))
    assert.truthy(html:find('data-lab-stories', 1, true))
    assert.falsy(html:find('data-lab-rulers', 1, true))
    assert.falsy(html:find('data-lab-preferences', 1, true))
    local bare = server.renderToString(H.h(C.Grid, { unstyled=true, style="background:red" }))
    assert.falsy(bare:find('hydronium-lab__world-grid', 1, true))
    assert.truthy(bare:find('background:red', 1, true))
    for _, name in ipairs({ "Grid", "Rulers", "Guides", "RulerHandle", "Toolbar", "Inspector", "Preferences", "NavigationSettings", "GridSettings", "ZoomIn", "ZoomOut" }) do
      assert.equal(type(C[name]), "function")
    end
  end)
  it("lets default workbenches omit sections and choose their arrangement", function()
    local W = require("hydronium_lab.workbench")
    local server = require("hydronium_dom.server")
    local html = server.renderToString(H.h(W.Shell, { layout="stacked", sidebar=false, preferences_panel=false, rulers=false, guides=false, ruler_handle=false, grid=false }))
    assert.truthy(html:find('data-lab-layout="stacked"', 1, true))
    for _, role in ipairs({ "sidebar", "preferences", "rulers", "guide-layer", "ruler-hit", "grid" }) do
      assert.falsy(html:find('data-lab-' .. role .. '=', 1, true))
    end
    local dom = server.renderToString(H.h(require("hydronium_lab.dom_document").Shell, { sidebar=false, toolbar=false, preferences_panel=false }))
    assert.falsy(dom:find('data-lab-sidebar=', 1, true))
    assert.falsy(dom:find('data-lab-toolbar=', 1, true))
  end)
  it("binds a Markdown story from a record that only carries its path", function()
    -- The browser DOM Lab builds records without `transform`; an .mdx story
    -- must still bind as a DOM story instead of "must return a Lab value".
    local component = function() return H.h("p", nil, "doc") end
    local story = lab.discovery.bind({ path = "src/Guide.stories.mdx", id_prefix = "guide", stem = "Guide" }, component)
    assert.equal(story.id, "guide--default")
    assert.equal(story.renderer, "dom")
    story = lab.discovery.bind({ path = "src/Guide.stories.md", id_prefix = "g", stem = "Guide", transform = "" }, component)
    assert.equal(story.id, "g--default")
  end)

  it("validates renderer metadata and preserves collection and variant choices", function()
    local record = { path = "src/Mixed.stories.lua", id_prefix = "mixed", stem = "Mixed" }
    local collection = lab.collection({ renderer = "dom", viewports = { { name = "Card", width = 480, height = 640 } }, component = function() end, stories = { dom = {}, terminal = { renderer = "ink" } } })
    local registry = lab.discovery.registry({ record }, function() return collection end)
    assert.equal(registry.get("mixed--dom").renderer, "dom")
    assert.equal(registry.get("mixed--terminal").renderer, "ink")
    assert.equal(registry.manifest()[1].renderer, "dom")
    assert.equal(registry.manifest()[1].viewports[1].width, 480)
    assert.falsy(pcall(lab.story, { id = "bad-size", render = function() end, viewports = { { width = 0 } } }))
    assert.falsy(pcall(lab.story, { id = "bad", renderer = "canvas", render = function() end }))
  end)
  it("updates props and hooks without remounting and disposes restarted stories", function()
    local setups, cleanups = 0, 0
    local function Counter()
      setups = setups + 1
      local args = lab.useStoryArgs()
      local count, setCount = H.signal(1)
      H.onCleanup(function() cleanups = cleanups + 1 end)
      return function() return H.h("button", { onClick = function() setCount(count() + 1) end }, args().label .. ":" .. count()) end
    end
    package.loaded["hydronium_lab.dom_stories"] = lab.registry({ lab.story({ id = "counter", renderer = "dom", args = { label = "A" }, controls = { label = { type = "text" } }, render = function() return H.h(Counter) end }) })
    local preview = require("hydronium_lab.dom_preview")
    local view = H.test.render(H.h(preview.App, { story = "counter" }))
    assert.equal(view:text(), "A:1")
    preview.request({ op = "args", args = { label = "B" } })
    assert.equal(view:text(), "B:1"); assert.equal(setups, 1)
    assert.falsy(pcall(preview.request, { op = "args", args = { label = 2 } }))
    preview.request({ op = "restart" }); assert.equal(setups, 2); assert.equal(cleanups, 1)
    assert.equal(view:text(), "B:1")
    view:unmount(); assert.equal(cleanups, 2)
    assert.falsy(pcall(preview.request, { op = "snapshot" }))
    package.loaded["hydronium_lab.dom_stories"] = nil
  end)
  it("ignores require-like comments and emits browser-loadable preload chunks", function()
    local compiler = require("hydronium_meteorite.dom_lab")
    local ids = compiler.requires('-- require("secret")\nlocal message = "require(\'secret\')"\nlocal H = require("hydronium")')
    assert.equal(#ids, 1); assert.equal(ids[1], "hydronium")
    local bundle = compiler.bundle({ example = 'return "browser module"' })
    local chunk = (loadstring or load)(bundle)
    assert.truthy(chunk); chunk(); assert.equal(require("example"), "browser module")
    package.loaded.example = nil; package.preload.example = nil
  end)
  it("loads Lua stories importing LuaX siblings and rejects unlisted browser assets", function()
    local previousH, previousRuntime = _G.H, _G.__luax
    local host = require("hydronium_meteorite.lab")
    host.reset_for_test()
    local path = os.tmpname()
    local file = io.open(path, "wb")
    file:write('return { renderer="mixed", roots={"tests/fixtures/lab_mixed"}, module_roots={"tests/fixtures/lab_mixed"}, paths={"tests/fixtures/lab_mixed/Counter.stories.lua","tests/fixtures/lab_mixed/Terminal.stories.lua"} }')
    file:close()
    local previous = package.path
    package.path = "tests/fixtures/lab_mixed/?.lua;" .. package.path
    local routes = {}
    local app = { get=function(_, route) routes[route]=true end, post=function() end, delete=function() end }
    host.mount(app, { config_path=path, base_path="/lab" })
    local context = { req_headers=function() return {} end, header=function() return nil end, request_header=function() return nil end,
      json=function(_, first, value) return value or first end, text=function(_, status) return status end,
      bytes=function(_, status, mime, body) return body end,
      param=function() return "../secret" end }
    local catalog = host.catalog(context)
    assert.truthy(catalog.ok)
    assert.equal(#catalog.catalog.stories, 3)
    assert.truthy(routes["/lab/assets/dom-client/:path*"])
    assert.equal(host.dom_asset(context), 404)
    local ink = host.ink_preview(context)
    assert.truthy(ink:find("data%-hydronium%-ink%-lab"), "Lua shims must take precedence over same-named LuaX source")
    assert.truthy(ink:find("ink%-preview.js"))
    assert.truthy(ink:find("data%-lab%-terminal"))
    assert.falsy(ink:find("data%-lab%-stage"), "Ink preview must not nest another workbench canvas")
    assert.falsy(ink:find("data%-lab%-sidebar"))
    local modules = host.dom_modules(context)
    assert.truthy(modules.ok); assert.truthy(modules.modules.Counter)
    assert.truthy(modules.modules["hydronium_lab.story_1"]:find("discovery", 1, true))
    package.path = previous; package.loaded.Counter=nil
    host.reset_for_test(); os.remove(path)
    _G.H, _G.__luax = previousH, previousRuntime
  end)
  it("serves Ink story sources to a browser transport named in the config", function()
    local previousH, previousRuntime = _G.H, _G.__luax
    local host = require("hydronium_meteorite.lab")
    local function configure(extra)
      host.reset_for_test()
      local path = os.tmpname()
      local file = io.open(path, "wb")
      file:write('return { renderer="mixed", roots={"tests/fixtures/lab_mixed"}, module_roots={"tests/fixtures/lab_mixed"}, paths={"tests/fixtures/lab_mixed/Counter.stories.lua","tests/fixtures/lab_mixed/Terminal.stories.lua"}' .. extra .. ' }')
      file:close()
      local routes = {}
      host.mount({ get=function(_, route) routes[route]=true end, post=function() end, delete=function() end }, { config_path=path, base_path="/lab" })
      return path, routes
    end
    local previous = package.path
    package.path = "tests/fixtures/lab_mixed/?.lua;" .. package.path
    local context = { header=function() return nil end, json=function(_, first, value) if type(first) == "number" then return value end return first end,
      text=function(_, status) return status end, bytes=function(_, status, mime, body) return body end }

    local path, routes = configure(', ink_transport="/assets/ink-transport.js?v=1"')
    assert.truthy(routes["/lab/ink/modules"])
    assert.truthy(host.ink_preview(context):find('data-lab-ink-transport="/assets/ink-transport.js?v=1"', 1, true))
    local served = host.ink_modules(context)
    assert.truthy(served.ok)
    assert.truthy(served.modules["hydronium_lab.ink_stories"]:find("story_2", 1, true), "only the Ink collection is registered")
    assert.falsy(served.modules["hydronium_lab.ink_stories"]:find("story_1", 1, true))
    assert.truthy(served.modules["hydronium_ink_lab.service"])
    assert.truthy(served.modules["hydronium_ink.host.terminal"])
    assert.equal(served.modules["hydronium_ink.yoga_ffi"], nil, "the transport supplies native modules")
    assert.equal(served.modules["hydronium_ink.tty_ffi"], nil)
    -- A fresh Lua state (release builds use one per request) reports the
    -- same catalog, so previews do not reopen their story on every poll.
    local first = host.catalog(context)
    host.reset_for_test()
    host.mount({ get=function() end, post=function() end, delete=function() end }, { config_path=path, base_path="/lab" })
    local second = host.catalog(context)
    assert.equal(first.generation, second.generation)
    assert.equal(first.instance, second.instance)
    os.remove(path)

    path = configure(', ink_transport="//evil.example/x.js"')
    assert.falsy(pcall(host.ink_preview, context), "a transport must be a same-origin path")
    os.remove(path)
    path = configure("")
    assert.falsy(host.ink_preview(context):find("data-lab-ink-transport", 1, true))
    os.remove(path)
    package.path = previous; package.loaded.Counter=nil
    host.reset_for_test()
    _G.H, _G.__luax = previousH, previousRuntime
  end)

  it("loads an MDX component and its LUAX import in the DOM Lab preview", function()
    local previousH, previousRuntime = _G.H, _G.__luax
    local host = require("hydronium_meteorite.lab")
    host.reset_for_test()
    local config_path = os.tmpname()
    local file = io.open(config_path, "wb")
    file:write('return { renderer="dom", roots={"tests/fixtures/lab_mixed"}, module_roots={"tests/fixtures/lab_mixed"}, paths={"tests/fixtures/lab_mixed/Markdown.stories.lua","tests/fixtures/lab_mixed/Guide.stories.mdx"} }')
    file:close()
    local previous = package.path
    package.path = "tests/fixtures/lab_mixed/?.lua;" .. previous
    local app = { get=function() end, post=function() end, delete=function() end }
    host.mount(app, { config_path=config_path, base_path="/lab" })
    local context = { req_headers=function() return {} end, header=function() return nil end, request_header=function() return nil end,
      json=function(_, first, value) return value or first end, text=function(_, status) return status end,
      bytes=function(_, status, mime, body) return body end }
    local catalog = host.catalog(context)
    assert.truthy(catalog.ok)
    assert.equal(#catalog.catalog.stories, 2)
    assert.equal(catalog.catalog.stories[1].renderer, "dom")
    local modules = host.dom_modules(context)
    assert.truthy(modules.ok)
    assert.truthy(modules.modules.Docs:find('H.h%(HydroniumMdH1'))
    assert.truthy(modules.modules.Docs:find('require%("DocsBadge"%)'))
    assert.truthy(modules.modules.DocsBadge)
    assert.truthy(modules.modules["hydronium_lab.story_1"]:find("Direct documentation story", 1, true))
    package.path = previous
    package.loaded.Docs = nil; package.loaded.DocsBadge = nil
    host.reset_for_test(); os.remove(config_path)
    _G.H, _G.__luax = previousH, previousRuntime
  end)
  it("renders a source-accessible mixed workbench without Ink-specific markup", function()
    local previousRuntime = _G.__luax
    _G.__luax = require("hydronium_luax.runtime")
    local html = require("hydronium_dom.server").renderToString(H.h(require("hydronium_lab.dom_document").Document, {
      boot = lab.host.contract({ base_path = "/tools/lab" }), project_name = "Mixed",
    }))
    _G.__luax = previousRuntime
    assert.truthy(html:find("data%-hydronium%-dom%-lab"))
    assert.truthy(html:find("data%-lab%-dom%-preview"))
    assert.truthy(html:find('aria%-label="Selected story tools"'))
    assert.truthy(html:find('data%-lab%-hints%-enabled'))
    assert.truthy(html:find('data%-lab%-hint'))
    assert.truthy(html:find('data%-lab%-stage') < html:find('aria%-label="Selected story tools"'))
    assert.truthy(html:find("data%-lab%-ink%-color"))
    assert.falsy(html:find("Terminal color</summary>", 1, true), "Ink color remains an inline selector")
    assert.falsy(html:find("data%-lab%-terminal"))
  end)
end)
