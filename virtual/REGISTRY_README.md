# hydronium/virtual

Host-neutral virtual-list geometry. It owns item measurement and visible-range
calculation; a DOM scroll handler, an Ink viewport, or another host supplies
the viewport and scroll offset.

## Install and calculate a range

In an empty directory:

```sh
moon init . --name demo --interpreter luajit@2.1
moon add hydronium/virtual
```

Save demo.lua:

```lua
local virtual = require("hydronium_virtual")
local list = virtual.createVirtualizer({
  count = 100, estimate_size = 20, overscan = 0,
})
list:setViewportSize(40)
list:setScrollOffset(20)
for _, item in ipairs(list:getVirtualItems()) do
  print(item.index .. ":" .. item.start .. ":" .. item.size)
end
```

```sh
moon exec -- luajit demo.lua
```

Expected output:

```text
1:20:20
2:40:20
```

Each line is index:start:size; the range covers the viewport at offset
20 in a 2,000-pixel list. All positions are geometry, not DOM nodes. The script
needs no browser. Next, render only those items and update viewport/offset from
your host's scroll events.

## Measure and bind a host


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

The following browser integration fragment also needs hydronium/dom. It
assumes list, scroll_ref, item and row_ref belong to your mounted component.
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
