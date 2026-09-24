# hydronium/virtual

Host-neutral virtual-list geometry. It owns item measurement and visible-range
calculation; a DOM scroll handler, an Ink viewport, or another host supplies
the viewport and scroll offset.

```lua
local virtual = require("hydronium_virtual")
local list = virtual.createVirtualizer({ count = function() return #rows() end, estimate_size = 36, overscan = 3, axis = "vertical" })

list:setViewportSize(height)
list:setScrollOffset(scroll_top)
for _, item in ipairs(list:getVirtualItems()) do
  -- render rows()[item.index + 1] at item.start, with item.size
end
```

Call `measure(index, size)` after a host observes an actual row size. Indices
are zero-based because they describe physical layout positions; application
row arrays remain ordinary Lua one-based arrays. Range lookup, offsets, and a
single measurement update are logarithmic in item count. Measurements are kept
by `key`, so use a stable record ID when rows can be prepended or reordered.

For sticky or always-mounted items, supply `range_extractor = function(range)
return { 0, range.overscan_start, range.overscan_end } end`. It receives the
visible and overscanned zero-based range and returns the exact indices to
render; Hydronium validates, deduplicates, and orders them physically.

Set `axis = "horizontal"` for columns or a horizontal strip. The geometry API
stays the same; the DOM adapter reads `scrollLeft` and element width instead of
`scrollTop` and height. If an application needs browser-specific RTL scroll
normalization, keep that policy at its DOM boundary before giving the resulting
logical offset to the virtualizer.

Attach a host after the scroll container ref is mounted:

```lua
local dom_virtual = require("hydronium_dom.virtual")
local binding = virtual.bind(list, dom_virtual.createVirtualHost(scroll_ref, { axis = "vertical" }))

-- Call once for each rendered row ref. Cleanup follows the surrounding
-- Hydronium scope, or call binding:dispose() when managing it yourself.
binding:observeItem(item.index, row_ref)
```

For SSR or restoring a navigation, pass `initial_viewport_size` and an
`initial_snapshot = { offset = ..., sizes = ... }` returned by `takeSnapshot()`.
