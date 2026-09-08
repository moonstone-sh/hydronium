--[[
  hydronium_ink.measure -- measureElement(ref), matching real Ink's own
  top-level export of the same name. Reads a host node's last-computed
  layout directly off the node table itself (`node._layout`, set by
  host/terminal.lua's resolvePositions() on every paint() and never
  cleared afterward -- the real Yoga node backing it is freed each
  paint, per buildYogaTree()'s own doc comment, but the plain Lua
  `_layout` table survives on the node and is exactly what this reads).

  A `ref` here is an ordinary `hydronium.createRef()` bound via a real
  `ref` prop on a Box/Text/etc element (core/reconciler.lua binds
  `vnode.ref` to the host node on mount/update/unmount -- see
  core/ref.lua's bindRef/unbindRef) -- nothing ink-specific about the
  ref mechanism itself, only about what `.current` ends up holding
  (this host's own internal node table) and what this module knows how
  to read off of it.
--]]

local M = {}

---@class hydronium_ink.ElementMetrics
---@field x integer
---@field y integer
---@field width integer
---@field height integer
---@field clientWidth integer Content-box width (inside border+padding).
---@field clientHeight integer Content-box height (inside border+padding).
---@field hasMeasured boolean False before the ref's element has ever been painted.

--- @param ref table A `hydronium.createRef()` whose `.current` was bound
---   via a `ref` prop on a mounted `ink.Box`/`ink.Text`/etc element.
--- @return hydronium_ink.ElementMetrics
function M.measureElement(ref)
  local node = ref and ref.current
  local layout = node and node._layout
  if not layout then
    return { x = 0, y = 0, width = 0, height = 0, clientWidth = 0, clientHeight = 0, hasMeasured = false }
  end
  return {
    x = layout.x,
    y = layout.y,
    width = layout.w,
    height = layout.h,
    clientWidth = layout.clientW or layout.w,
    clientHeight = layout.clientH or layout.h,
    hasMeasured = true,
  }
end

return M
