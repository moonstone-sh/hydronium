-- Headless table state. This package does not render tags or assume a DOM;
-- applications decide how headers, cells, selection, and virtualization look.
local core = require("hydronium.core")
local engine = require("hydronium_table.engine")
local M, Table = {}, {}
Table.__index = Table

local function source(value) return type(value) == "function" and value() or value end
local function copy(array)
  local out = {}
  for i = 1, #(array or {}) do out[i] = array[i] end
  return out
end

local function column_map(columns)
  local by_id = {}
  for _, column in ipairs(columns or {}) do
    if type(column.id) ~= "string" or column.id == "" then error("hydronium.table columns require a non-empty id", 3) end
    if by_id[column.id] then error("hydronium.table column ids must be unique", 3) end
    if type(column.accessor) ~= "function" then error("hydronium.table column " .. column.id .. " requires accessor(row)", 3) end
    by_id[column.id] = column
  end
  return by_id
end

function M.createTable(options)
  options = options or {}
  if options.rows == nil then error("hydronium.table.createTable requires rows", 2) end
  local columns = options.columns or {}
  local sorting, set_sorting = core.createSignal(copy(options.sorting))
  local filters, set_filters = core.createSignal({})
  local selection, set_selection = core.createSignal({})
  local visibility, set_visibility = core.createSignal({})
  local order, set_order = core.createSignal({})
  local sizing, set_sizing = core.createSignal({})
  local pinning, set_pinning = core.createSignal(options.column_pinning or options.columnPinning or { left = {}, right = {} })
  local expanded, set_expanded = core.createSignal(options.expanded or {})
  local grouping, set_grouping = core.createSignal(copy(options.grouping))
  local global_filter, set_global_filter = core.createSignal(options.global_filter or options.globalFilter)
  local page, set_page = core.createSignal(0)
  return setmetatable({ _rows = options.rows, columns = columns, by_id = column_map(columns), _row_models = options.row_models,
    _row_id = options.row_id or options.rowId or function(_, index) return index end,
    _get_sub_rows = options.get_sub_rows or options.getSubRows,
    _page_size = options.page_size or options.pageSize,
    _sorting = sorting, _set_sorting = set_sorting, _filters = filters, _set_filters = set_filters,
    _selection = selection, _set_selection = set_selection, _page = page, _set_page = set_page,
    _visibility = visibility, _set_visibility = set_visibility, _order = order, _set_order = set_order,
    _sizing = sizing, _set_sizing = set_sizing,
    _pinning = pinning, _set_pinning = set_pinning,
    _expanded = expanded, _set_expanded = set_expanded,
    _grouping = grouping, _set_grouping = set_grouping, _aggregations = options.aggregations or {},
    _global_filter = global_filter, _set_global_filter = set_global_filter, _global_filter_fn = options.global_filter_fn or options.globalFilterFn,
    _state = options.state or {}, _on_state_change = options.on_state_change or options.onStateChange or {},
    _manual_sorting = options.manual_sorting or options.manualSorting,
    _manual_filtering = options.manual_filtering or options.manualFiltering,
    _manual_global_filter = options.manual_global_filter or options.manualGlobalFiltering,
    _manual_pagination = options.manual_pagination or options.manualPagination,
    _row_count = options.row_count or options.rowCount,
  }, Table)
end

function Table:_state_value(name, fallback)
  local value = self._state[name]
  if value == nil then return fallback() end
  return source(value)
end
function Table:_set_state(name, value, fallback)
  local callback = self._on_state_change[name]
  if callback then callback(value) else fallback(value) end
end
function Table:sorting() return self:_state_value("sorting", self._sorting) end
function Table:setSorting(value) self:_set_state("sorting", copy(value), self._set_sorting); self:setPage(0) end
Table.set_sorting = Table.setSorting
function Table:toggleSort(id, multi)
  if not self.by_id[id] then error("hydronium.table has no column " .. tostring(id), 2) end
  local sorting = self:sorting()
  if not multi then
    local current = sorting[1]
    if current and current.id == id then
      if current.desc then self:setSorting({}) else self:setSorting({ { id = id, desc = true } }) end
    else self:setSorting({ { id = id, desc = false } }) end
    return
  end
  local next_sorting, found = {}, false
  for _, current in ipairs(sorting) do
    if current.id == id then
      found = true
      if not current.desc then next_sorting[#next_sorting + 1] = { id = id, desc = true } end
    else
      next_sorting[#next_sorting + 1] = { id = current.id, desc = current.desc }
    end
  end
  if not found then next_sorting[#next_sorting + 1] = { id = id, desc = false } end
  self:setSorting(next_sorting)
end
Table.toggle_sort = Table.toggleSort

function Table:setFilter(id, value)
  if not self.by_id[id] then error("hydronium.table has no column " .. tostring(id), 2) end
  local next_filters = {}
  for key, current in pairs(self:filters()) do next_filters[key] = current end
  next_filters[id] = value
  self:_set_state("filters", next_filters, self._set_filters); self:setPage(0)
end
Table.set_filter = Table.setFilter
function Table:filters() return self:_state_value("filters", self._filters) end
function Table:globalFilter() return self:_state_value("global_filter", self._global_filter) end
Table.global_filter = Table.globalFilter
function Table:setGlobalFilter(value) self:_set_state("global_filter", value, self._set_global_filter); self:setPage(0) end
Table.set_global_filter = Table.setGlobalFilter

function Table:columnVisibility() return self:_state_value("column_visibility", self._visibility) end
Table.column_visibility = Table.columnVisibility
function Table:setColumnVisibility(value) self:_set_state("column_visibility", value, self._set_visibility) end
Table.set_column_visibility = Table.setColumnVisibility
function Table:setColumnOrder(value)
  for _, id in ipairs(value) do if not self.by_id[id] then error("hydronium.table has no column " .. tostring(id), 2) end end
  self:_set_state("column_order", value, self._set_order)
end
Table.set_column_order = Table.setColumnOrder
function Table:visibleColumns()
  local visibility, order = self:columnVisibility(), self:_state_value("column_order", self._order)
  if self._visible_cache and self._visible_cache.visibility == visibility and self._visible_cache.order == order then return self._visible_cache.columns end
  local out, seen = {}, {}
  for _, id in ipairs(order) do if not visibility[id] then out[#out + 1], seen[id] = self.by_id[id], true end end
  for _, column in ipairs(self.columns) do if not seen[column.id] and not visibility[column.id] then out[#out + 1] = column end end
  self._visible_cache = { visibility = visibility, order = order, columns = out }
  return out
end
Table.visible_columns = Table.visibleColumns

local function validate_pinning(self, value)
  if type(value) ~= "table" then error("hydronium.table column pinning must be a table", 3) end
  local seen = {}
  for _, side in ipairs({ "left", "right" }) do
    if value[side] ~= nil and type(value[side]) ~= "table" then error("hydronium.table column pinning." .. side .. " must be an array", 3) end
    for _, id in ipairs(value[side] or {}) do
      if not self.by_id[id] then error("hydronium.table has no column " .. tostring(id), 3) end
      if seen[id] then error("hydronium.table cannot pin a column on both sides", 3) end
      seen[id] = true
    end
  end
end
function Table:columnPinning() return self:_state_value("column_pinning", self._pinning) end
Table.column_pinning = Table.columnPinning
function Table:setColumnPinning(value)
  value = value or { left = {}, right = {} }; validate_pinning(self, value)
  self:_set_state("column_pinning", { left = copy(value.left), right = copy(value.right) }, self._set_pinning)
end
Table.set_column_pinning = Table.setColumnPinning
--- Pins a column to `left`/`right`, or unpins it with nil/false.
function Table:pinColumn(id, side)
  if not self.by_id[id] then error("hydronium.table has no column " .. tostring(id), 2) end
  if side ~= nil and side ~= false and side ~= "left" and side ~= "right" then error("hydronium.table pin side must be left, right, or nil", 2) end
  local current, next_pinning = self:columnPinning(), { left = {}, right = {} }
  for _, position in ipairs({ "left", "right" }) do
    for _, current_id in ipairs(current[position] or {}) do if current_id ~= id then next_pinning[position][#next_pinning[position] + 1] = current_id end end
  end
  if side then next_pinning[side][#next_pinning[side] + 1] = id end
  self:setColumnPinning(next_pinning)
end
Table.pin_column = Table.pinColumn
--- Returns renderer-ready `{ left = {}, center = {}, right = {} }` leaf columns.
--- Pin arrays determine the edge order; unpinned visible columns retain normal order.
function Table:getColumnGroups()
  local visible, pinning, by_id = self:visibleColumns(), self:columnPinning(), self.by_id
  local groups, pinned = { left = {}, center = {}, right = {} }, {}
  for _, side in ipairs({ "left", "right" }) do
    for _, id in ipairs(pinning[side] or {}) do
      local column = by_id[id]
      local is_visible = false
      for _, visible_column in ipairs(visible) do if visible_column.id == id then is_visible = true; break end end
      if column and is_visible then groups[side][#groups[side] + 1], pinned[id] = column, true end
    end
  end
  for _, column in ipairs(visible) do if not pinned[column.id] then groups.center[#groups.center + 1] = column end end
  return groups
end
Table.get_column_groups = Table.getColumnGroups

function Table:columnSizing() return self:_state_value("column_sizing", self._sizing) end
Table.column_sizing = Table.columnSizing
function Table:setColumnSizing(value) self:_set_state("column_sizing", value, self._set_sizing) end
Table.set_column_sizing = Table.setColumnSizing
function Table:columnSize(id)
  local column = self.by_id[id]
  if not column then error("hydronium.table has no column " .. tostring(id), 2) end
  return self:columnSizing()[id] or column.size or column.min_size or 0
end
Table.column_size = Table.columnSize
function Table:resizeColumn(id, delta)
  if type(delta) ~= "number" then error("hydronium.table resize delta must be a number", 2) end
  local column, current = self.by_id[id], self:columnSize(id)
  if not column then error("hydronium.table has no column " .. tostring(id), 2) end
  local next_sizing = {}; for key, value in pairs(self:columnSizing()) do next_sizing[key] = value end
  next_sizing[id] = math.max(column.min_size or 0, math.min(column.max_size or math.huge, current + delta))
  self:setColumnSizing(next_sizing)
  return next_sizing[id]
end
Table.resize_column = Table.resizeColumn

function Table:getRows()
  local raw, filters, global_filter, sorting, columns = source(self._rows), self:filters(), self:globalFilter(), self:sorting(), self:visibleColumns()
  local cache = self._row_cache
  if cache and cache.raw == raw and cache.filters == filters and cache.global_filter == global_filter and cache.sorting == sorting and cache.columns == columns
    and cache.manual_filtering == self._manual_filtering and cache.manual_global_filter == self._manual_global_filter and cache.manual_sorting == self._manual_sorting then
    return cache.rows
  end
  local model_options = {
    manual_filtering = self._manual_filtering, manual_global_filter = self._manual_global_filter, manual_sorting = self._manual_sorting,
    global_filter = global_filter, global_filter_fn = self._global_filter_fn,
  }
  local rows = self._row_models
    and engine.pipeline(raw, columns, self.by_id, self._row_id, filters, sorting, model_options, self._row_models)
    or engine.rows(raw, columns, self.by_id, self._row_id, filters, sorting, model_options)
  self._row_cache = { raw = raw, filters = filters, global_filter = global_filter, sorting = sorting, columns = columns, manual_filtering = self._manual_filtering, manual_global_filter = self._manual_global_filter, manual_sorting = self._manual_sorting, rows = rows }
  return rows
end
Table.get_rows = Table.getRows

function Table:expanded() return self:_state_value("expanded", self._expanded) end
function Table:setExpanded(value)
  if type(value) ~= "table" then error("hydronium.table expanded state must be a table", 2) end
  self:_set_state("expanded", value, self._set_expanded)
end
Table.set_expanded = Table.setExpanded
function Table:toggleExpanded(id)
  local next_expanded = {}
  for key, value in pairs(self:expanded()) do next_expanded[key] = value end
  id = tostring(id); next_expanded[id] = not next_expanded[id] or nil
  self:setExpanded(next_expanded)
end
Table.toggle_expanded = Table.toggleExpanded
function Table:isExpanded(id) return self:expanded()[tostring(id)] == true end
Table.is_expanded = Table.isExpanded
--- Returns root rows plus expanded descendants. `getRows()` deliberately
--- remains the flat root model, which keeps server pagination unambiguous.
function Table:getExpandedRows()
  return engine.expand(self:getRows(), self:visibleColumns(), self._row_id, self._get_sub_rows, self:expanded())
end
Table.get_expanded_rows = Table.getExpandedRows

function Table:grouping() return self:_state_value("grouping", self._grouping) end
function Table:setGrouping(value)
  for _, id in ipairs(value or {}) do if not self.by_id[id] then error("hydronium.table has no column " .. tostring(id), 2) end end
  self:_set_state("grouping", copy(value), self._set_grouping)
end
Table.set_grouping = Table.setGrouping
function Table:getGroupedRows()
  return engine.group(self:getRows(), self:grouping(), self.by_id, self._aggregations)
end
Table.get_grouped_rows = Table.getGroupedRows
--- A renderer-ready flat group/leaf list. Group ids use the existing expanded
--- state, so `toggleExpanded(group.id)` works for group headers and trees.
function Table:getExpandedGroupedRows()
  return engine.flatten(self:getGroupedRows(), self:expanded())
end
Table.get_expanded_grouped_rows = Table.getExpandedGroupedRows

local function faceted_rows(self, except_id)
  local raw, filters = source(self._rows), {}
  for id, value in pairs(self:filters()) do if id ~= except_id then filters[id] = value end end
  local rows = engine.core(raw, self._row_id)
  if not self._manual_filtering then rows = engine.filter(rows, self.by_id, filters) end
  if not self._manual_global_filter then rows = engine.global_filter(rows, self:visibleColumns(), self:globalFilter(), self._global_filter_fn) end
  return rows
end
--- Counts each raw scalar value after every other local filter is applied.
--- The column's own filter is omitted so a filter menu can show alternatives.
function Table:getFacetedUniqueValues(id)
  local column = self.by_id[id]
  if not column then error("hydronium.table has no column " .. tostring(id), 2) end
  return engine.unique_values(faceted_rows(self, id), column)
end
Table.get_faceted_unique_values = Table.getFacetedUniqueValues
--- Returns `{ min = number, max = number }` for numeric values, or nil when
--- the faceted rows contain no numbers.
function Table:getFacetedMinMaxValues(id)
  local column = self.by_id[id]
  if not column then error("hydronium.table has no column " .. tostring(id), 2) end
  return engine.min_max_values(faceted_rows(self, id), column)
end
Table.get_faceted_min_max_values = Table.getFacetedMinMaxValues

function Table:pageCount()
  if not self._page_size then return 1 end
  local count = self._manual_pagination and source(self._row_count) or #self:getRows()
  if count == nil then error("hydronium.table manual_pagination requires row_count", 2) end
  return math.max(1, math.ceil(count / self._page_size))
end
function Table:page() return self:_state_value("page", self._page) end
function Table:setPage(value) self:_set_state("page", math.max(0, math.min(value, self:pageCount() - 1)), self._set_page) end
Table.set_page = Table.setPage
function Table:getPageRows()
  local rows = self:getRows()
  if not self._page_size or self._manual_pagination then return rows end
  return engine.page(rows, self:page(), self._page_size)
end
Table.get_page_rows = Table.getPageRows

function Table:selection() return self:_state_value("selection", self._selection) end
function Table:toggleSelected(id)
  local next_selection = {}
  for key, value in pairs(self:selection()) do next_selection[key] = value end
  id = tostring(id); next_selection[id] = not next_selection[id] or nil
  self:_set_state("selection", next_selection, self._set_selection)
end
Table.toggle_selected = Table.toggleSelected
function Table:isSelected(id) return self:selection()[tostring(id)] == true end
Table.is_selected = Table.isSelected

M.Table = Table
M.create_table = M.createTable
return M
