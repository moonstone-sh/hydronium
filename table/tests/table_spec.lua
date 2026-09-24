local test = require("tests.runner")
local table_api = require("hydronium_table")

test.describe("hydronium/table", function()
  test.it("filters, sorts, paginates, and tracks selection without rendering", function()
    local users = table_api.createTable({
      rows = { { id = "a", name = "Ada", active = true }, { id = "g", name = "Grace", active = false }, { id = "l", name = "Lin", active = true } },
      row_id = function(row) return row.id end, page_size = 1,
      columns = {
        { id = "name", accessor = function(row) return row.name end },
        { id = "active", accessor = function(row) return row.active end },
      },
    })
    users:setFilter("active", true); users:toggleSort("name")
    test.assert.equal(#users:getRows(), 2)
    test.assert.equal(users:getPageRows()[1].cells.name, "Ada")
    users:setPage(1); test.assert.equal(users:getPageRows()[1].cells.name, "Lin")
    users:toggleSelected("l"); test.assert.truthy(users:isSelected("l"))
  end)

  test.it("supports controlled state and manual server row models", function()
    local changes, sorting = {}, {}
    local users = table_api.createTable({
      rows = { { id = "b", name = "Beta" }, { id = "a", name = "Alpha" } },
      columns = { { id = "name", accessor = function(row) return row.name end } },
      state = { sorting = function() return sorting end },
      on_state_change = { sorting = function(value) changes.sorting = value end },
      manual_sorting = true,
    })
    users:toggleSort("name")
    test.assert.equal(changes.sorting[1].id, "name")
    test.assert.equal(users:getRows()[1].cells.name, "Beta", "manual sorting leaves server order intact")
  end)

  test.it("sorts by every declared sort key and cycles opt-in multi-sort state", function()
    local users = table_api.createTable({
      rows = { { team = "a", name = "Lin" }, { team = "a", name = "Ada" }, { team = "b", name = "Bob" } },
      columns = { { id = "team", accessor = function(row) return row.team end }, { id = "name", accessor = function(row) return row.name end } },
    })
    users:setSorting({ { id = "team", desc = false }, { id = "name", desc = false } })
    test.assert.equal(users:getRows()[1].cells.name, "Ada")
    users:toggleSort("team", true)
    test.assert.truthy(users:sorting()[1].desc)
    users:toggleSort("team", true)
    test.assert.equal(users:sorting()[1].id, "name", "third multi-sort activation removes that key")
  end)

  test.it("preserves controlled filters and accepts later server pages", function()
    local filters, page, changed = { active = true }, 0, {}
    local users = table_api.createTable({
      rows = { { name = "server page" } }, page_size = 1, row_count = 3, manual_pagination = true,
      columns = { { id = "name", accessor = function(row) return row.name end }, { id = "active", accessor = function(row) return row.active end } },
      state = { filters = function() return filters end, page = function() return page end },
      on_state_change = { filters = function(value) changed.filters = value end, page = function(value) changed.page = value end },
    })
    users:setFilter("name", "Ada"); users:setPage(2)
    test.assert.truthy(changed.filters.active)
    test.assert.equal(changed.page, 2)
  end)

  test.it("memoizes the row model until an explicit state input changes", function()
    local table = table_api.createTable({ rows = { { name = "Ada" } }, columns = { { id = "name", accessor = function(row) return row.name end } } })
    local first = table:getRows()
    test.assert.equal(first, table:getRows())
    table:toggleSort("name")
    test.assert.not_equal(first, table:getRows())
  end)

  test.it("accepts a composable pure row-model pipeline", function()
    local table = table_api.createTable({
      rows = { { name = "Ada" }, { name = "Lin" } }, columns = { { id = "name", accessor = function(row) return row.name end } },
      row_models = { function(rows) return { rows[2] } end },
    })
    test.assert.equal(table:getRows()[1].cells.name, "Lin")
  end)

  test.it("keeps the standard filter and sort stages when a custom model is present", function()
    local seen = {}
    local table = table_api.createTable({
      rows = { { name = "Lin", active = true }, { name = "Ada", active = true }, { name = "Bob", active = false } },
      columns = {
        { id = "name", accessor = function(row) return row.name end },
        { id = "active", accessor = function(row) return row.active end },
      },
      row_models = { function(rows) seen.count, seen.first = #rows, rows[1].original.name; return rows end },
    })
    table:setFilter("active", true); table:toggleSort("name")
    local rows = table:getRows()
    test.assert.equal(seen.count, 2)
    test.assert.equal(seen.first, "Ada")
    test.assert.equal(rows[1].cells.name, "Ada")
  end)

  test.it("orders and hides columns without changing row identity", function()
    local table = table_api.createTable({ rows = { { name = "Ada", email = "a@x" } }, columns = {
      { id = "name", accessor = function(row) return row.name end }, { id = "email", accessor = function(row) return row.email end },
    } })
    table:setColumnOrder({ "email" }); table:setColumnVisibility({ name = true })
    test.assert.equal(table:visibleColumns()[1].id, "email")
    test.assert.is_nil(table:getRows()[1].cells.name)
    test.assert.equal(table:getRows()[1].cells.email, "a@x")
  end)

  test.it("resizes columns within declared bounds", function()
    local table = table_api.createTable({ rows = {}, columns = { { id = "name", size = 100, min_size = 80, max_size = 120, accessor = function() end } } })
    test.assert.equal(table:resizeColumn("name", 50), 120)
    test.assert.equal(table:resizeColumn("name", -100), 80)
  end)

  test.it("models pinned column groups without requiring a renderer", function()
    local table = table_api.createTable({ rows = {}, columns = {
      { id = "name", accessor = function() end }, { id = "email", accessor = function() end }, { id = "status", accessor = function() end },
    } })
    table:setColumnOrder({ "status", "name", "email" })
    table:setColumnPinning({ left = { "name" }, right = { "email" } })
    local groups = table:getColumnGroups()
    test.assert.equal(groups.left[1].id, "name")
    test.assert.equal(groups.center[1].id, "status")
    test.assert.equal(groups.right[1].id, "email")
    table:pinColumn("name")
    test.assert.equal(#table:getColumnGroups().left, 0)
  end)

  test.it("flattens controlled expansion state with depth and parent identity", function()
    local expanded, changed = {}, nil
    local table = table_api.createTable({
      rows = { { id = "root", name = "Root", children = { { id = "child", name = "Child" } } } },
      row_id = function(row) return row.id end,
      get_sub_rows = function(row) return row.children end,
      columns = { { id = "name", accessor = function(row) return row.name end } },
      state = { expanded = function() return expanded end },
      on_state_change = { expanded = function(value) changed = value end },
    })
    test.assert.equal(#table:getExpandedRows(), 1)
    table:toggleExpanded("root")
    test.assert.truthy(changed.root)
    expanded = changed
    local rows = table:getExpandedRows()
    test.assert.equal(#rows, 2)
    test.assert.equal(rows[2].cells.name, "Child")
    test.assert.equal(rows[2].depth, 1)
    test.assert.equal(rows[2].parent_id, "root")
  end)

  test.it("facets against every other local filter and preserves Lua scalar keys", function()
    local table = table_api.createTable({
      rows = { { team = "a", score = 10, active = true }, { team = "a", score = 20, active = false }, { team = "b", score = 30, active = true } },
      columns = {
        { id = "team", accessor = function(row) return row.team end },
        { id = "score", accessor = function(row) return row.score end },
        { id = "active", accessor = function(row) return row.active end },
      },
    })
    table:setFilter("team", "a"); table:setFilter("active", true)
    local teams, active, range = table:getFacetedUniqueValues("team"), table:getFacetedUniqueValues("active"), table:getFacetedMinMaxValues("score")
    test.assert.equal(teams.a, 1)
    test.assert.equal(teams.b, 1, "the team facet ignores its own selected value")
    test.assert.equal(active[true], 1)
    test.assert.equal(active[false], 1, "the active facet ignores its own selected value")
    test.assert.equal(range.min, 10); test.assert.equal(range.max, 10)
  end)

  test.it("globally filters visible columns and composes with facets", function()
    local table = table_api.createTable({
      rows = { { name = "Ada", role = "Admin" }, { name = "Lin", role = "Editor" }, { name = "Bob", role = "Admin" } },
      columns = { { id = "name", accessor = function(row) return row.name end }, { id = "role", accessor = function(row) return row.role end } },
    })
    table:setGlobalFilter("ada")
    test.assert.equal(#table:getRows(), 1)
    test.assert.equal(table:getRows()[1].cells.name, "Ada")
    test.assert.equal(table:getFacetedUniqueValues("role").Admin, 1)
  end)

  test.it("groups filtered leaf rows and flattens expanded groups with aggregates", function()
    local table = table_api.createTable({
      rows = { { team = "a", score = 2 }, { team = "a", score = 3 }, { team = "b", score = 9 } },
      columns = { { id = "team", accessor = function(row) return row.team end }, { id = "score", accessor = function(row) return row.score end } },
      grouping = { "team" },
      aggregations = { score = function(rows) local total = 0; for _, row in ipairs(rows) do total = total + row.original.score end; return total end },
    })
    local groups = table:getGroupedRows()
    test.assert.equal(groups[1].group_value, "a")
    test.assert.equal(groups[1].cells.score, 5)
    test.assert.equal(#table:getExpandedGroupedRows(), 2, "collapsed group headers only")
    table:toggleExpanded(groups[1].id)
    local expanded = table:getExpandedGroupedRows()
    test.assert.equal(#expanded, 4)
    test.assert.equal(expanded[2].cells.team, "a")
    test.assert.equal(expanded[2].depth, 1)
  end)
end)
