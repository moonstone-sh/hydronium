local test = require("tests.runner")
local virtual = require("hydronium_virtual")

test.describe("hydronium/virtual", function()
  test.it("calculates an overscanned visible range and accepts measurements", function()
    local list = virtual.createVirtualizer({ count = 10, estimate_size = 10, overscan = 1 })
    list:setViewportSize(20); list:setScrollOffset(20)
    local items = list:getVirtualItems()
    test.assert.equal(items[1].index, 1)
    test.assert.equal(items[#items].index, 4)
    list:measure(1, 20)
    test.assert.equal(list:offsetOf(2), 30)
    test.assert.equal(list:totalSize(), 110)
  end)

  test.it("scrolls by item alignment", function()
    local list = virtual.createVirtualizer({ count = 10, estimate_size = 10 })
    list:setViewportSize(30)
    test.assert.equal(list:scrollToIndex(5, "center"), 40)
    test.assert.equal(list:scrollToIndex(5, "end"), 30)
  end)

  test.it("uses caller keys and makes a measurement observable", function()
    local list = virtual.createVirtualizer({ count = 2, estimate_size = 10, key = function(index) return "row-" .. index end })
    list:setViewportSize(20)
    test.assert.equal(list:getVirtualItems()[1].key, "row-0")
    list:measure(0, 12)
    test.assert.equal(list:getVirtualItems()[1].size, 12)
  end)

  test.it("makes orientation explicit without changing one-dimensional geometry", function()
    local strip = virtual.createVirtualizer({ count = 3, estimate_size = 20, axis = "horizontal" })
    strip:setViewportSize(30)
    test.assert.equal(strip:axis(), "horizontal")
    test.assert.equal(strip:getVirtualItems()[2].start, 20)
  end)

  test.it("rebuilds keyed measurements when rows reorder at the same count", function()
    local rows, revision = { "a", "b" }, 0
    local list = virtual.createVirtualizer({ count = function() return #rows end, estimate_size = 10, key = function(index) return rows[index + 1] end, key_revision = function() return revision end })
    list:measure(0, 100)
    rows, revision = { "b", "a" }, 1
    test.assert.equal(list:size(0), 10)
    test.assert.equal(list:size(1), 100)
  end)

  test.it("binds plain host observations and physical scrolling without putting host code in geometry", function()
    local viewport, offset, physical = nil, nil, nil
    local list = virtual.createVirtualizer({ count = 4, estimate_size = 10, overscan = 0 })
    local binding = virtual.bind(list, {
      observeViewport = function(fn) viewport = fn; return function() viewport = nil end end,
      observeOffset = function(fn) offset = fn; return function() offset = nil end end,
      scrollTo = function(value) physical = value end,
    })
    viewport(20); offset(10)
    test.assert.equal(list:getVirtualItems()[1].index, 1)
    binding:scrollToIndex(3, "end")
    test.assert.equal(physical, 20)
    binding:dispose(); test.assert.is_nil(viewport); test.assert.is_nil(offset)
  end)

  test.it("seeds SSR geometry and restores a measured snapshot", function()
    local list = virtual.createVirtualizer({ count = 3, estimate_size = 10, initial_viewport_size = 20, initial_snapshot = { offset = 10, sizes = { [0] = 30 } } })
    test.assert.equal(list:scrollOffset(), 10)
    test.assert.equal(list:size(0), 30)
    test.assert.equal(list:getVirtualItems()[1].index, 0)
  end)

  test.it("keeps the visible anchor stable when an item above it grows", function()
    local list = virtual.createVirtualizer({ count = 10, estimate_size = 10 })
    list:setScrollOffset(50)
    list:measure(1, 25)
    test.assert.equal(list:scrollOffset(), 65)
  end)

  test.it("lets renderer policy add stable items to the extracted range", function()
    local list = virtual.createVirtualizer({
      count = 10, estimate_size = 10, overscan = 0,
      range_extractor = function(range) return { 0, range.start_index, range.end_index, 0 } end,
    })
    list:setViewportSize(20); list:setScrollOffset(30)
    local items = list:getVirtualItems()
    test.assert.equal(#items, 3)
    test.assert.equal(items[1].index, 0)
    test.assert.equal(items[2].index, 3)
    test.assert.equal(items[3].index, 4)
  end)
end)
