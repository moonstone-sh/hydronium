--[[
  Hydronium LUAX Tree-sitter Benchmark Suite
  Measures:
  1. Initial parse latency across small, medium, and large LUAX documents (p50, p95, max)
  2. Single-keystroke incremental edit latency in live Neovim buffer (p50, p95, max)
  3. Syntax tree integrity verification
--]]

local function compute_percentiles(samples)
  table.sort(samples)
  local n = #samples
  local p50 = samples[math.max(1, math.floor(n * 0.50))]
  local p95 = samples[math.max(1, math.floor(n * 0.95))]
  local max_val = samples[n]
  return p50, p95, max_val
end

local function generate_small_fixture()
  return [[local hydronium = require("hydronium")
local d = hydronium.d

local function SimpleCard(props)
  return (
    <d.main class="card">
      <d.header>
        <d.h1>{props.title}</d.h1>
      </d.header>
      <d.section>
        <d.input type="text" placeholder="Enter name..." />
        <d.button onClick={function() print("submitted") end}>
          Submit
        </d.button>
      </d.section>
    </d.main>
  )
end

return SimpleCard
]]
end

local function generate_medium_fixture()
  local lines = {
    'local hydronium = require("hydronium")',
    'local d = hydronium.d',
    '',
    'local function Dashboard(props)',
    '  return (',
    '    <d.main class="dashboard-root">',
    '      <d.header class="top-nav">',
    '        <d.h1>Hydronium Admin Console</d.h1>',
    '        <d.nav class="links">',
    '          <d.a href="/overview">Overview</d.a>',
    '          <d.a href="/metrics">Metrics</d.a>',
    '          <d.a href="/settings">Settings</d.a>',
    '        </d.nav>',
    '      </d.header>',
    '      <d.section class="metrics-grid">',
  }
  for i = 1, 15 do
    table.insert(lines, string.format('        <d.article class="metric-card" id="card-%d">', i))
    table.insert(lines, string.format('          <d.h3>System Metric #%d</d.h3>', i))
    table.insert(lines, string.format('          <d.p class="metric-value">%d,420 ms</d.p>', i * 12))
    table.insert(lines, '          <d.button class="btn-refresh" onClick={function() end}>Refresh</d.button>')
    table.insert(lines, '        </d.article>')
  end
  table.insert(lines, '      </d.section>')
  table.insert(lines, '      <d.footer>')
  table.insert(lines, '        <d.p>Powered by Hydronium LUAX & Neovim</d.p>')
  table.insert(lines, '      </d.footer>')
  table.insert(lines, '    </d.main>')
  table.insert(lines, '  )')
  table.insert(lines, 'end')
  table.insert(lines, 'return Dashboard')
  return table.concat(lines, "\n")
end

local function generate_large_fixture()
  local lines = {
    'local hydronium = require("hydronium")',
    'local d = hydronium.d',
    'local UI = require("my_ui_lib")',
    '',
    'local function LargeApplicationView(props)',
    '  return (',
    '    <d.div class="app-container">',
    '      <d.header class="app-header">',
    '        <d.h1>Large Enterprise Workspace</d.h1>',
    '      </d.header>',
  }
  for section = 1, 20 do
    table.insert(lines, string.format('      <d.section class="data-section-%d">', section))
    table.insert(lines, string.format('        <d.h2>Section %d: Complex Form & Table Grid</d.h2>', section))
    table.insert(lines, '        <d.form class="grid-form">')
    for field = 1, 6 do
      table.insert(lines, string.format('          <d.label for="field-%d-%d">Field %d-%d</d.label>', section, field, section, field))
      table.insert(lines, string.format('          <d.input id="field-%d-%d" name="field_%d_%d" value={props.val} />', section, field, section, field))
    end
    table.insert(lines, '          <d.button type="submit">Update Records</d.button>')
    table.insert(lines, '        </d.form>')
    table.insert(lines, '        <UI.Card elevation={2} variant="outlined">')
    table.insert(lines, '          <d.span>Embedded Component Card</d.span>')
    table.insert(lines, '        </UI.Card>')
    table.insert(lines, '      </d.section>')
  end
  table.insert(lines, '    </d.div>')
  table.insert(lines, '  )')
  table.insert(lines, 'end')
  table.insert(lines, 'return LargeApplicationView')
  return table.concat(lines, "\n")
end

local function run_initial_parse_benchmark(fixture_name, source, iterations)
  local samples_us = {}
  local lang = "luax"

  -- Warmup
  for _ = 1, 5 do
    local parser = vim.treesitter.get_string_parser(source, lang)
    parser:parse()
  end

  for _ = 1, iterations do
    local t0 = vim.loop.hrtime()
    local parser = vim.treesitter.get_string_parser(source, lang)
    local tree = parser:parse()[1]
    local t1 = vim.loop.hrtime()
    assert(tree and tree:root():type() == "program", "Tree root must be program")
    table.insert(samples_us, (t1 - t0) / 1000.0)
  end

  local p50, p95, max_val = compute_percentiles(samples_us)
  return {
    name = fixture_name,
    lines = select(2, source:gsub("\n", "\n")) + 1,
    p50_us = p50,
    p95_us = p95,
    max_us = max_val,
  }
end

local function run_incremental_edit_benchmark(iterations)
  local buf = vim.api.nvim_create_buf(false, true)
  local initial_lines = vim.split(generate_medium_fixture(), "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

  local parser = vim.treesitter.get_parser(buf, "luax")
  parser:parse()

  local samples_us = {}

  for i = 1, iterations do
    -- Pick a line in the middle to edit (e.g. line 17)
    local line_idx = 16
    local char_to_insert = (i % 2 == 0) and "x" or "y"

    local t0 = vim.loop.hrtime()
    -- Insert single character at col 10
    vim.api.nvim_buf_set_text(buf, line_idx, 10, line_idx, 10, { char_to_insert })
    local tree = parser:parse()[1]
    local t1 = vim.loop.hrtime()

    assert(tree and tree:root():type() == "program", "Incremental tree root must be program")
    table.insert(samples_us, (t1 - t0) / 1000.0)

    -- Clean up the character to keep document valid
    vim.api.nvim_buf_set_text(buf, line_idx, 10, line_idx, 11, { "" })
    parser:parse()
  end

  vim.api.nvim_buf_delete(buf, { force = true })

  local p50, p95, max_val = compute_percentiles(samples_us)
  return {
    p50_us = p50,
    p95_us = p95,
    max_us = max_val,
  }
end

local function main()
  print("==================================================================")
  print("         Hydronium LUAX Tree-sitter Latency Benchmarks            ")
  print("==================================================================")

  local small_src = generate_small_fixture()
  local med_src = generate_medium_fixture()
  local large_src = generate_large_fixture()

  local res_small = run_initial_parse_benchmark("Small Fixture", small_src, 50)
  local res_med = run_initial_parse_benchmark("Medium Fixture", med_src, 50)
  local res_large = run_initial_parse_benchmark("Large Fixture", large_src, 50)

  print("\n### 1. Initial Parse Latency (50 iterations)")
  print("| Fixture        | Lines | p50 Latency | p95 Latency | Max Latency |")
  print("|----------------|-------|-------------|-------------|-------------|")
  for _, r in ipairs({ res_small, res_med, res_large }) do
    print(string.format("| %-14s | %5d | %8.2f µs | %8.2f µs | %8.2f µs |",
      r.name, r.lines, r.p50_us, r.p95_us, r.max_us))
  end

  print("\n### 2. Single-Keystroke Incremental Edit Latency (100 iterations)")
  local inc_res = run_incremental_edit_benchmark(100)
  print("| Operation                   | Samples | p50 Latency | p95 Latency | Max Latency |")
  print("|-----------------------------|---------|-------------|-------------|-------------|")
  print(string.format("| Incremental Buffer Reparse  |     100 | %8.2f µs | %8.2f µs | %8.2f µs |",
    inc_res.p50_us, inc_res.p95_us, inc_res.max_us))

  -- Verification against performance budgets
  print("\n### 3. Performance Budget Validation")
  local ok = true

  local function check_budget(name, actual, limit, unit)
    if actual <= limit then
      print(string.format("  ✓ PASS %s: %.2f %s <= %.2f %s", name, actual, unit, limit, unit))
    else
      print(string.format("  ✗ FAIL %s: %.2f %s > %.2f %s", name, actual, unit, limit, unit))
      ok = false
    end
  end

  check_budget("Small initial parse p50", res_small.p50_us, 1500.0, "µs")
  check_budget("Medium initial parse p50", res_med.p50_us, 5000.0, "µs")
  check_budget("Large initial parse p50", res_large.p50_us, 25000.0, "µs")
  check_budget("Incremental edit p50", inc_res.p50_us, 150.0, "µs")
  check_budget("Incremental edit p95", inc_res.p95_us, 500.0, "µs")

  if not ok then
    os.exit(1)
  end
  print("\nTree-sitter performance benchmarks PASSED successfully.")
end

main()
