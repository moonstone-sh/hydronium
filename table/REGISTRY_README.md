# hydronium/table

Headless, reactive row modeling for Hydronium. It owns no markup, styles, or
DOM event policy, so the same table can render in DOM or Ink.

```lua
local table = require("hydronium_table")
local users = table.createTable({
  rows = users_signal,
  row_id = function(user) return user.id end,
  page_size = 25,
  columns = {
    { id = "name", header = "Name", accessor = function(user) return user.name end },
    { id = "email", header = "Email", accessor = function(user) return user.email end },
  },
})

-- In a component render: users:getPageRows(), users:toggleSort("name"),
-- users:setFilter("email", "ada@example.com"), users:toggleSelected(row.id).
```

For large lists, pass `#users:getPageRows()` to `hydronium/virtual` and map
its zero-based `item.index` back to Lua's one-based table with `rows[index + 1]`.

For server-owned filtering, sorting, or pagination, set `manual_sorting`,
`manual_filtering`, or `manual_pagination`, provide that state through
`state = { sorting = accessor, ... }`, and receive user intent through
`on_state_change = { sorting = function(next) ... end, ... }`. The table then
keeps server row order and never applies that transform locally.

Columns are stateful too: `setColumnVisibility`, `setColumnOrder`, and
`resizeColumn` provide headless visibility, ordering, and bounded sizing.
`visibleColumns()` and each row's `cells` are already in that effective order,
so renderers do not need to repeat the policy.

Use `setColumnPinning({ left = { "name" }, right = { "actions" } })` and
`getColumnGroups()` for sticky-edge layouts. The result has `left`, `center`,
and `right` arrays; the renderer chooses how those groups become DOM sticky
columns or an Ink layout. `pinColumn(id, "left" | "right" | nil)` is the
single-column convenience form.

Tree data is opt-in: pass `get_sub_rows = function(row) return row.children
end`, then render `getExpandedRows()` instead of `getRows()`. Expansion state
uses the same `state` / `on_state_change` pattern with the `expanded` key.
Returned descendants carry `depth` and `parent_id`, so renderers can indent
them without discovering structure themselves.

Filter menus can use `getFacetedUniqueValues(column_id)` for value counts and
`getFacetedMinMaxValues(column_id)` for numeric bounds. Both apply the other
local filters while intentionally excluding that column's own filter, so a UI
can offer alternatives to the active selection.

`setGlobalFilter(query)` searches the currently visible columns with a
case-insensitive substring match. Supply `global_filter_fn` when records need
domain-specific matching; `manual_global_filter` leaves that work to a server.

`setSorting` accepts multiple `{ id = ..., desc = boolean }` entries and the
engine uses them in order. `toggleSort(id)` keeps the ordinary single-column
cycle; `toggleSort(id, true)` adds, reverses, then removes that key without
discarding the other sort keys.

For grouped reports, set `grouping = { "team" }` or call `setGrouping`, and
provide `aggregations = { score = function(rows) ... end }` (or a column's
`aggregate` function). `getGroupedRows()` returns a tree of group nodes; use
`getExpandedGroupedRows()` for an ordered flat list controlled by the normal
`expanded` state.

For an application-specific row model, pass `row_models = { function(rows,
context) return rows end }`. Models run as pure transforms after normal local
filtering and sorting, but before cell construction. This keeps grouping or
expansion policy out of the DOM and makes it testable without a renderer. Set
the corresponding `manual_*` flag when the server owns a base stage.
