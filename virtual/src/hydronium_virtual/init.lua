-- Host-neutral virtual geometry. A Fenwick tree keeps offsets, measurements,
-- and range lookup logarithmic; hosts only supply scroll/viewport observation.
local core = require("hydronium.core")
local Engine = require("hydronium_virtual.engine")
local M, Virtualizer = {}, {}
Virtualizer.__index = Virtualizer

local function resolve(value) return type(value) == "function" and value() or value end
local function positive(value, name)
  if type(value) ~= "number" or value <= 0 then error("hydronium.virtual " .. name .. " must be a positive number", 3) end
  return value
end
local function default_range(range)
  local out = {}
  for index = range.overscan_start, range.overscan_end do out[#out + 1] = index end
  return out
end

function M.createVirtualizer(options)
  options = options or {}
  if options.count == nil then error("hydronium.virtual.createVirtualizer requires count", 2) end
  local estimate = options.estimate_size or options.estimateSize or 32
  local axis = options.axis or "vertical"
  if axis ~= "vertical" and axis ~= "horizontal" then error("hydronium.virtual axis must be vertical or horizontal", 2) end
  if type(estimate) ~= "number" and type(estimate) ~= "function" then error("hydronium.virtual estimate_size must be a number or function", 2) end
  local snapshot = options.initial_snapshot or options.initialSnapshot or {}
  local offset, set_offset = core.createSignal(options.initial_offset or options.initialOffset or snapshot.offset or 0)
  local viewport, set_viewport = core.createSignal(options.initial_viewport_size or options.initialViewportSize or 0)
  local revision, set_revision = core.createSignal(0)
  return setmetatable({ _count = options.count, _estimate = estimate, _axis = axis, _overscan = options.overscan or 1,
    _range_extractor = options.range_extractor or options.rangeExtractor or default_range,
    _key = options.key or options.getItemKey or function(index) return index end,
    _key_revision = options.key_revision or options.keyRevision, _tree_key_revision = nil,
    _sizes_by_key = snapshot.sizes or {}, _tree = {}, _tree_count = -1, _offset = offset, _set_offset = set_offset,
    _viewport = viewport, _set_viewport = set_viewport, _revision = revision, _set_revision = set_revision,
    _padding_start = options.padding_start or options.paddingStart or 0, _padding_end = options.padding_end or options.paddingEnd or 0,
    _adjust_scroll = options.adjust_scroll ~= false and options.adjustScroll ~= false,
  }, Virtualizer)
end
function Virtualizer:axis() return self._axis end
function Virtualizer:count()
  local count = resolve(self._count)
  if type(count) ~= "number" or count < 0 or count ~= math.floor(count) then error("hydronium.virtual count must resolve to a non-negative integer", 2) end
  return count
end
function Virtualizer:_estimate_at(index) return positive(type(self._estimate) == "function" and self._estimate(index) or self._estimate, "estimate_size") end
function Virtualizer:_ensure()
  local count, key_revision = self:count(), resolve(self._key_revision)
  if self._tree_count == count and self._tree_key_revision == key_revision then return count end
  self._tree_count, self._tree_key_revision = count, key_revision
  self._tree = Engine.new(count, function(index) return self:_estimate_at(index) end, self._key, self._sizes_by_key)
  return count
end
--- Call after a same-count reorder when no reactive key_revision accessor was supplied.
function Virtualizer:invalidate()
  self._tree_count = -1
  self._set_revision(self._revision() + 1)
end
function Virtualizer:size(index)
  self._revision(); local count = self:_ensure()
  if index < 0 or index >= count then error("hydronium.virtual index is out of range", 2) end
  return self._tree:size(index)
end
function Virtualizer:measure(index, size)
  positive(size, "measured size"); local count = self:_ensure()
  if index < 0 or index >= count then error("hydronium.virtual index is out of range", 2) end
  local key, prior, start, scroll = self._key(index), self:size(index), self:offsetOf(index), self:scrollOffset()
  self._sizes_by_key[key] = size; self._tree:measure(index, size)
  if self._adjust_scroll and start < scroll then self:setScrollOffset(scroll + size - prior) end
  self._set_revision(self._revision() + 1)
end
function Virtualizer:offsetOf(index)
  self._revision(); local count = self:_ensure()
  if index < 0 or index > count then error("hydronium.virtual index is out of range", 2) end
  return self._padding_start + self._tree:offset(index)
end
Virtualizer.offset_of = Virtualizer.offsetOf
function Virtualizer:totalSize() self._revision(); self:_ensure(); return self._padding_start + self._tree:total() + self._padding_end end
Virtualizer.total_size = Virtualizer.totalSize
function Virtualizer:setScrollOffset(value) self._set_offset(math.max(0, value or 0)) end
Virtualizer.set_scroll_offset = Virtualizer.setScrollOffset
function Virtualizer:scrollOffset() return self._offset() end
Virtualizer.scroll_offset = Virtualizer.scrollOffset
function Virtualizer:setViewportSize(value) self._set_viewport(math.max(0, value or 0)) end
Virtualizer.set_viewport_size = Virtualizer.setViewportSize
function Virtualizer:viewportSize() return self._viewport() end
Virtualizer.viewport_size = Virtualizer.viewportSize
function Virtualizer:_index_at(offset)
  local count, tree = self:_ensure(), self._tree
  if count == 0 then return 0 end
  return tree:index_at(offset - self._padding_start)
end
function Virtualizer:getVirtualItems()
  self._revision(); local count, scroll, viewport = self:_ensure(), self:scrollOffset(), self:viewportSize()
  if count == 0 or viewport == 0 then return {} end
  local visible_start = self:_index_at(scroll)
  local visible_end = self:_index_at(math.max(scroll, scroll + viewport - 1e-9))
  local start = math.max(0, visible_start - self._overscan)
  -- The viewport is half-open: an item starting exactly at its trailing edge
  -- is not visible, but may be added once by overscan below.
  local finish = math.min(count - 1, visible_end + self._overscan)
  local requested = self._range_extractor({ start_index = visible_start, end_index = visible_end, overscan_start = start, overscan_end = finish, count = count })
  if type(requested) ~= "table" then error("hydronium.virtual range_extractor must return an array of indices", 2) end
  local indices, seen = {}, {}
  for _, index in ipairs(requested) do
    if type(index) ~= "number" or index ~= math.floor(index) or index < 0 or index >= count then error("hydronium.virtual range_extractor returned an out-of-range index", 2) end
    if not seen[index] then indices[#indices + 1], seen[index] = index, true end
  end
  table.sort(indices)
  local items = {}
  for _, index in ipairs(indices) do items[#items + 1] = { index = index, key = self._key(index), start = self:offsetOf(index), size = self:size(index) } end
  return items
end
Virtualizer.get_virtual_items = Virtualizer.getVirtualItems
function Virtualizer:scrollToIndex(index, align)
  local start, size, viewport = self:offsetOf(index), self:size(index), self:viewportSize()
  local target = align == "end" and start + size - viewport or align == "center" and start - (viewport - size) / 2 or start
  if align and align ~= "start" and align ~= "center" and align ~= "end" then error("hydronium.virtual align must be start, center, or end", 2) end
  self:setScrollOffset(target); return self:scrollOffset()
end
Virtualizer.scroll_to_index = Virtualizer.scrollToIndex
function Virtualizer:takeSnapshot()
  local sizes = {}; for key, size in pairs(self._sizes_by_key) do sizes[key] = size end
  return { offset = self:scrollOffset(), sizes = sizes }
end
M.Virtualizer, M.create_virtualizer = Virtualizer, M.createVirtualizer
M.bind = require("hydronium_virtual.binding").bind
return M
