-- Deterministic table row transforms. No signals, scopes, hosts, or rendering.
local M = {}

function M.core(raw, row_id)
  if type(raw) ~= "table" then error("hydronium.table rows must resolve to an array", 3) end
  local rows = {}
  for index, original in ipairs(raw) do
    rows[#rows + 1] = { id = tostring(row_id(original, index)), index = index, original = original }
  end
  return rows
end
function M.filter(rows, by_id, filters)
  local out = {}
  for _, row in ipairs(rows) do
    local include = true
    for id, wanted in pairs(filters) do
      local column, value = by_id[id], by_id[id].accessor(row.original, row.index)
      if column.filter then include = column.filter(value, wanted, row.original) else include = value == wanted end
      if not include then break end
    end
    if include then out[#out + 1] = row end
  end
  return out
end
function M.global_filter(rows, columns, query, matcher)
  if query == nil or query == "" then return rows end
  local out, needle = {}, string.lower(tostring(query))
  for _, row in ipairs(rows) do
    local include
    if matcher then
      include = matcher(row.original, query, columns, row.index)
    else
      include = false
      for _, column in ipairs(columns) do
        local value = column.accessor(row.original, row.index)
        if value ~= nil and string.find(string.lower(tostring(value)), needle, 1, true) then include = true; break end
      end
    end
    if include then out[#out + 1] = row end
  end
  return out
end
function M.sort(rows, by_id, sorting)
  for _, sort in ipairs(sorting) do
    if not by_id[sort.id] then error("hydronium.table has no column " .. tostring(sort.id), 3) end
  end
  if #sorting > 0 then
    table.sort(rows, function(a, b)
      for _, sort in ipairs(sorting) do
        local column = by_id[sort.id]
        local av, bv = column.accessor(a.original, a.index), column.accessor(b.original, b.index)
        if av ~= bv then
          local less = column.compare and column.compare(av, bv, a.original, b.original) or av < bv
          return sort.desc and not less or less
        end
      end
      return a.index < b.index
    end)
  end
  return rows
end
function M.cells(rows, columns)
  for _, row in ipairs(rows) do
    row.cells = {}
    for _, column in ipairs(columns) do row.cells[column.id] = column.accessor(row.original, row.index) end
  end
  return rows
end
function M.rows(raw, columns, by_id, row_id, filters, sorting, options)
  options = options or {}
  local rows = M.core(raw, row_id)
  if not options.manual_filtering then rows = M.filter(rows, by_id, filters) end
  if not options.manual_global_filter then rows = M.global_filter(rows, columns, options.global_filter, options.global_filter_fn) end
  if not options.manual_sorting then rows = M.sort(rows, by_id, sorting) end
  return M.cells(rows, columns)
end

-- A row model is `fun(rows, context) -> rows`. Core, filtering and sorting are
-- the invariant base pipeline; cells are always last. Caller models therefore
-- see the same filtered/sorted rows whether or not an application needs
-- grouping, aggregation, or expansion between them and cell construction.
function M.pipeline(raw, columns, by_id, row_id, filters, sorting, options, models)
  options = options or {}
  local context = { columns = columns, by_id = by_id, filters = filters, sorting = sorting, options = options }
  local rows = M.core(raw, row_id)
  if not options.manual_filtering then rows = M.filter(rows, by_id, filters) end
  if not options.manual_global_filter then rows = M.global_filter(rows, columns, options.global_filter, options.global_filter_fn) end
  if not options.manual_sorting then rows = M.sort(rows, by_id, sorting) end
  for _, model in ipairs(models or {}) do rows = model(rows, context) end
  return M.cells(rows, columns)
end

M.models = {
  filter = function(rows, context) return context.options.manual_filtering and rows or M.filter(rows, context.by_id, context.filters) end,
  sort = function(rows, context) return context.options.manual_sorting and rows or M.sort(rows, context.by_id, context.sorting) end,
}

function M.page(rows, page, page_size)
  if not page_size then return rows end
  local start, out = page * page_size + 1, {}
  for i = start, math.min(#rows, start + page_size - 1) do out[#out + 1] = rows[i] end
  return out
end

-- Flattens an already-modeled tree in display order. Children are deliberately
-- not implicitly filtered or sorted: child semantics remain an application
-- data concern, or can be modeled explicitly before rendering.
function M.expand(rows, columns, row_id, get_sub_rows, expanded)
  if type(get_sub_rows) ~= "function" then return rows end
  local out = {}
  local function visit(row, depth, parent_id)
    row.depth, row.parent_id = depth, parent_id
    out[#out + 1] = row
    if not expanded[row.id] then return end
    local children = get_sub_rows(row.original, row.index) or {}
    if type(children) ~= "table" then error("hydronium.table get_sub_rows must return an array or nil", 3) end
    for index, child in ipairs(children) do
      local child_row = { id = tostring(row_id(child, index, row.original)), index = index, original = child, depth = depth + 1, parent_id = row.id }
      M.cells({ child_row }, columns)
      visit(child_row, depth + 1, row.id)
    end
  end
  for _, row in ipairs(rows) do visit(row, 0, nil) end
  return out
end

-- Facets operate on modeled row wrappers, before cells are constructed. Lua
-- scalar values are valid table keys, preserving `true`, 1 and "1" distinctly.
function M.unique_values(rows, column)
  local values = {}
  for _, row in ipairs(rows) do
    local value = column.accessor(row.original, row.index)
    if value ~= nil then values[value] = (values[value] or 0) + 1 end
  end
  return values
end

function M.min_max_values(rows, column)
  local min, max
  for _, row in ipairs(rows) do
    local value = column.accessor(row.original, row.index)
    if type(value) == "number" then
      min = min == nil and value or math.min(min, value)
      max = max == nil and value or math.max(max, value)
    end
  end
  return min == nil and nil or { min = min, max = max }
end

local function group_key(value)
  return type(value) .. ":" .. tostring(value)
end

-- Produces nested group nodes while retaining the original leaf rows. Each
-- aggregate is `fun(leaf_rows, group) -> value`; a column's `aggregate` is
-- used when no explicit aggregation is supplied for that column id.
function M.group(rows, grouping, by_id, aggregations)
  if #grouping == 0 then return rows end
  aggregations = aggregations or {}
  local function visit(input, level, parent_id)
    if level > #grouping then return input end
    local column_id, column = grouping[level], by_id[grouping[level]]
    if not column then error("hydronium.table has no column " .. tostring(column_id), 3) end
    local buckets, order = {}, {}
    for _, row in ipairs(input) do
      local value, key = column.accessor(row.original, row.index), group_key(column.accessor(row.original, row.index))
      local bucket = buckets[key]
      if not bucket then
        bucket = { value = value, rows = {} }; buckets[key] = bucket; order[#order + 1] = key
      end
      bucket.rows[#bucket.rows + 1] = row
    end
    local out = {}
    for _, key in ipairs(order) do
      local bucket = buckets[key]
      local id = (parent_id and parent_id .. "/" or "group:") .. column_id .. "=" .. key
      local node = { id = id, kind = "group", group_by = column_id, group_value = bucket.value, leaf_rows = bucket.rows, cells = {}, sub_rows = visit(bucket.rows, level + 1, id) }
      for id, aggregate in pairs(aggregations) do
        if type(aggregate) == "function" then node.cells[id] = aggregate(bucket.rows, node) end
      end
      for id, candidate in pairs(by_id) do
        if node.cells[id] == nil and type(candidate.aggregate) == "function" then node.cells[id] = candidate.aggregate(bucket.rows, node) end
      end
      out[#out + 1] = node
    end
    return out
  end
  return visit(rows, 1, nil)
end

-- Flattens a tree of group/leaf rows according to a caller-owned expansion map.
function M.flatten(rows, expanded)
  local out = {}
  local function visit(row, depth, parent_id)
    local copy = {}
    for key, value in pairs(row) do copy[key] = value end
    copy.depth, copy.parent_id = depth, parent_id
    out[#out + 1] = copy
    if row.sub_rows and expanded[row.id] then for _, child in ipairs(row.sub_rows) do visit(child, depth + 1, row.id) end end
  end
  for _, row in ipairs(rows) do visit(row, 0, nil) end
  return out
end

return M
