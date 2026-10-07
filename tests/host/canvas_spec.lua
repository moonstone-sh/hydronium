local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local hosts = require("hydronium.runtime.hosts")
local scope = require("hydronium.core.scope")
local ref = require("hydronium.core.ref")
local canvas = require("hydronium_dom.canvas")

-- A fake browser canvas: an element whose 2D context records calls.
local function fake_element(width, height)
  local calls = {}
  local ctx = setmetatable({ calls = calls }, { __index = function(_, name)
    return function(_, ...) calls[#calls + 1] = { name, ... } end
  end })
  local el = setmetatable({ clientWidth = width, clientHeight = height, width = 0, height = 0 }, {})
  function el:getContext(kind, options)
    calls[#calls + 1] = { "getContext", kind, options }
    return kind == "2d" and ctx or nil
  end
  return el, ctx, calls
end

local function with_host(bindings, fn)
  local _, release = hosts.install("canvas", 1, bindings)
  local ok, err = pcall(fn)
  release()
  if not ok then error(err, 0) end
end

describe("hydronium_dom.canvas", function()
  it("does nothing on the server (no canvas@1 capability)", function()
    local el = fake_element(10, 10)
    assert.falsy(canvas.available())
    assert.equal(canvas.context(el), nil)
    assert.equal(canvas.path("M0 0"), nil)
    assert.equal(canvas.pixel_ratio(), 1)
    local stop = canvas.frame(function() error("must not run") end)
    assert.equal(type(stop), "function")
    stop()
  end)

  it("gets a 2D context from an element or a ref", function()
    with_host({ device_pixel_ratio = function() return 1 end }, function()
      local el, ctx, calls = fake_element(10, 10)
      assert.equal(canvas.context(el), ctx)
      local r = ref.createRef()
      assert.equal(canvas.context(r), nil, "unmounted ref")
      r.current = el
      assert.equal(canvas.context(r, "2d", { alpha = false }), ctx)
      assert.same(calls[2], { "getContext", "2d", { alpha = false } })
    end)
  end)

  it("constructs through the host and loads images", function()
    local seen = {}
    with_host({
      path = function(init) seen.path = init; return "path" end,
      image_data = function(w, h) seen.size = { w, h }; return "blank" end,
      image_data_from = function(bytes, w) seen.bytes = { #bytes, w }; return "pixels" end,
      matrix = function(init) seen.matrix = init; return "matrix" end,
      offscreen = function(w, h) return { w, h } end,
      load_image = function(src) return "img:" .. src end,
    }, function()
      assert.equal(canvas.path("M0 0 L10 10"), "path")
      assert.equal(seen.path, "M0 0 L10 10")
      assert.equal(canvas.image_data(4, 2), "blank")
      assert.same(seen.size, { 4, 2 })
      assert.equal(canvas.image_data({ 255, 0, 0, 255 }, 1), "pixels")
      assert.same(seen.bytes, { 4, 1 })
      assert.equal(canvas.matrix("rotate(45deg)"), "matrix")
      assert.same(canvas.offscreen(8, 8), { 8, 8 })
      assert.equal(canvas.load_image("/a.png"), "img:/a.png")
    end)
  end)

  it("stops a frame loop when its component's scope is disposed", function()
    local stopped = 0
    with_host({ frame_loop = function(draw) return function() stopped = stopped + 1 end end }, function()
      local _, s = scope.createScope(function()
        canvas.frame(function() end)
      end)
      assert.equal(stopped, 0)
      s:dispose()
      assert.equal(stopped, 1)
    end)
  end)

  it("fits the backing store to CSS size times the pixel ratio", function()
    with_host({ device_pixel_ratio = function() return 2 end }, function()
      local el, ctx, calls = fake_element(150, 75)
      local got, w, h = canvas.fit(el)
      assert.equal(got, ctx)
      assert.equal(el.width, 300)
      assert.equal(el.height, 150)
      assert.equal(w, 150)
      assert.equal(h, 75)
      assert.same(calls[#calls], { "setTransform", 2, 0, 0, 2, 0, 0 })
    end)
  end)

  it("is declared to the bundler: canvas@1 is a known capability", function()
    local source = io.open("dom/src/hydronium_dom/canvas.lua"):read("*a")
    local scan = require("hydronium_ballad.host_capabilities").scan(source, {
      require("hydronium_dom.host.contract").manifest(),
      require("hydronium_dom.host.canvas_contract").manifest(),
    })
    assert.equal(#scan.unresolved, 0)
    assert.equal(scan.references[1].name, "canvas")
  end)
end)
