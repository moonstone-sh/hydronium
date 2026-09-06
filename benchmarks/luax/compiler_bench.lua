-- Hydronium LUAX Compiler Benchmark Suite
package.path = "src/?.lua;src/?/init.lua;./?.lua;./?/init.lua;" .. package.path

local luax = require("hydronium.luax")
local lexer = require("hydronium.luax.lexer")
local parser = require("hydronium.luax.parser")
local compiler = require("hydronium.luax.compiler")
local formatter = require("hydronium.luax.formatter")
local plugin = require("hydronium.luax.plugin")

local function count_lines(s)
  local c = 1
  for _ in s:gmatch("\n") do c = c + 1 end
  return c
end

local function run_benchmark(name, iterations, line_count, fn)
  -- Warm-up
  local warmup = math.min(10, math.max(1, math.floor(iterations * 0.05)))
  for _ = 1, warmup do
    fn()
  end

  collectgarbage("collect")

  local start_time = os.clock()
  for _ = 1, iterations do
    fn()
  end
  local end_time = os.clock()

  local elapsed_sec = end_time - start_time
  if elapsed_sec <= 0 then elapsed_sec = 0.000001 end

  local elapsed_ms = elapsed_sec * 1000
  local ops_per_sec = iterations / elapsed_sec
  local lines_per_sec = (iterations * line_count) / elapsed_sec
  local avg_latency_us = (elapsed_sec / iterations) * 1000000

  return {
    name = name,
    iterations = iterations,
    lines = line_count,
    elapsed_ms = elapsed_ms,
    ops_per_sec = ops_per_sec,
    lines_per_sec = lines_per_sec,
    avg_latency_us = avg_latency_us,
  }
end

local function format_number(n)
  local formatted = string.format("%.0f", n)
  local k
  while true do
    formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
    if k == 0 then break end
  end
  return formatted
end

-- Generate test fixtures of varying sizes
local small_src = [[
local function Button(props)
  local count, setCount = Hydronium.createSignal(props.initial or 0)
  return (
    <button class="btn" disabled={props.disabled} onClick={function() setCount(count() + 1) end}>
      {props.label}: {count()}
    </button>
  )
end
return Button
]]

local medium_parts = {
  "local function Dashboard(props)",
  "  local user, setUser = Hydronium.createSignal(props.user or 'Guest')",
  "  local activeTab, setActiveTab = Hydronium.createSignal('overview')",
  "  return (",
  "    <div class='dashboard-container'>",
  "      <header class='dash-header'>",
  "        <h1>Welcome, {user()}!</h1>",
  "        <nav class='tabs'>",
  "          <button class={activeTab() == 'overview' and 'active' or ''} onClick={function() setActiveTab('overview') end}>Overview</button>",
  "          <button class={activeTab() == 'analytics' and 'active' or ''} onClick={function() setActiveTab('analytics') end}>Analytics</button>",
  "          <button class={activeTab() == 'settings' and 'active' or ''} onClick={function() setActiveTab('settings') end}>Settings</button>",
  "        </nav>",
  "      </header>",
  "      <main class='dash-body'>",
}
for i = 1, 6 do
  table.insert(medium_parts, string.format("        <div class='metric-card' id='metric-%d'>", i))
  table.insert(medium_parts, string.format("          <span class='title'>Metric %d</span>", i))
  table.insert(medium_parts, string.format("          <span class='value'>%d,000</span>", i * 15))
  table.insert(medium_parts, "          <button onClick={function() print('details') end}>View Details</button>")
  table.insert(medium_parts, "        </div>")
end
table.insert(medium_parts, "      </main>")
table.insert(medium_parts, "      <footer class='dash-footer'>")
table.insert(medium_parts, "        <p>Dashboard v2.0 - All rights reserved</p>")
table.insert(medium_parts, "      </footer>")
table.insert(medium_parts, "    </div>")
table.insert(medium_parts, "  )")
table.insert(medium_parts, "end")
table.insert(medium_parts, "return Dashboard")
local medium_src = table.concat(medium_parts, "\n")

-- Generate 500+ lines fixture
local large_parts = {
  "local Hydronium = require('hydronium')",
  "local function Application(props)",
  "  local search, setSearch = Hydronium.createSignal('')",
  "  local items, setItems = Hydronium.createSignal({})",
  "  return (",
  "    <div id='app-root' class='full-layout'>",
}
for i = 1, 65 do
  table.insert(large_parts, string.format("      <section id='section-%d' class='panel'>", i))
  table.insert(large_parts, string.format("        <h2 class='panel-heading'>Section Heading %d</h2>", i))
  table.insert(large_parts, "        <div class='panel-content'>")
  table.insert(large_parts, string.format("          <p class='description'>Detailed info for item %d in our data catalog.</p>", i))
  table.insert(large_parts, string.format("          <input type='text' placeholder='Filter %d' value={search()} onInput={function(e) setSearch(e.value) end} />", i))
  table.insert(large_parts, string.format("          <button class='btn-action' onClick={function(ev) print('click', %d) end}>Action %d</button>", i, i))
  table.insert(large_parts, "        </div>")
  table.insert(large_parts, "      </section>")
end
table.insert(large_parts, "    </div>")
table.insert(large_parts, "  )")
table.insert(large_parts, "end")
table.insert(large_parts, "return Application")
local large_src = table.concat(large_parts, "\n")

local small_lines = count_lines(small_src)
local medium_lines = count_lines(medium_src)
local large_lines = count_lines(large_src)

local function main()
  print("===========================================================================================================")
  print("                                HYDRONIUM LUAX COMPILER BENCHMARK SUITE                                    ")
  print("===========================================================================================================")
  print(string.format("Lua Runtime: %s | OS: %s", _VERSION, package.config:sub(1, 1) == "/" and "Unix/macOS" or "Windows"))
  print(string.format("Fixtures: Small (%d lines) | Medium (%d lines) | Large (%d lines)\n",
    small_lines, medium_lines, large_lines))

  local results = {}

  -- 1. Lexer Tokenization
  table.insert(results, run_benchmark("Lexer: Tokenization (Small, 10 lines)", 5000, small_lines, function()
    local lx = lexer.new(small_src, "small.luax")
    while true do
      local tok = lx:next_token()
      if tok.type == "EOF" then break end
    end
  end))

  table.insert(results, run_benchmark("Lexer: Tokenization (Medium, ~50 lines)", 2000, medium_lines, function()
    local lx = lexer.new(medium_src, "medium.luax")
    while true do
      local tok = lx:next_token()
      if tok.type == "EOF" then break end
    end
  end))

  table.insert(results, run_benchmark("Lexer: Tokenization (Large, 500+ lines)", 200, large_lines, function()
    local lx = lexer.new(large_src, "large.luax")
    while true do
      local tok = lx:next_token()
      if tok.type == "EOF" then break end
    end
  end))

  -- 2. Parser AST Generation
  table.insert(results, run_benchmark("Parser: AST Generation (Small, 10 lines)", 2500, small_lines, function()
    parser.parse(small_src, "small.luax")
  end))

  table.insert(results, run_benchmark("Parser: AST Generation (Medium, ~50 lines)", 800, medium_lines, function()
    parser.parse(medium_src, "medium.luax")
  end))

  table.insert(results, run_benchmark("Parser: AST Generation (Large, 500+ lines)", 80, large_lines, function()
    parser.parse(large_src, "large.luax")
  end))

  -- 3. Code Emitter / Lowerer
  local small_ast = parser.parse(small_src, "small.luax")
  local medium_ast = parser.parse(medium_src, "medium.luax")
  local large_ast = parser.parse(large_src, "large.luax")

  table.insert(results, run_benchmark("Emitter: Code Emission (Small AST)", 5000, small_lines, function()
    compiler.compile(small_ast, { dev_mode = false })
  end))

  table.insert(results, run_benchmark("Emitter: Code Emission (Medium AST)", 2000, medium_lines, function()
    compiler.compile(medium_ast, { dev_mode = false })
  end))

  table.insert(results, run_benchmark("Emitter: Code Emission (Large AST)", 200, large_lines, function()
    compiler.compile(large_ast, { dev_mode = false })
  end))

  -- 4. Full Pipeline: Production Mode (no sourcemap)
  table.insert(results, run_benchmark("Compile: Production (Small, 10 lines)", 2000, small_lines, function()
    luax.compile(small_src, { dev_mode = false })
  end))

  table.insert(results, run_benchmark("Compile: Production (Medium, ~50 lines)", 600, medium_lines, function()
    luax.compile(medium_src, { dev_mode = false })
  end))

  table.insert(results, run_benchmark("Compile: Production (Large, 500+ lines)", 60, large_lines, function()
    luax.compile(large_src, { dev_mode = false })
  end))

  -- 5. Full Pipeline: Development Mode (__source + sourcemap)
  table.insert(results, run_benchmark("Compile: Dev + SourceMap (Small)", 1500, small_lines, function()
    luax.compile(small_src, { dev_mode = true, inline_sourcemap = true, filename = "small.luax" })
  end))

  table.insert(results, run_benchmark("Compile: Dev + SourceMap (Medium)", 400, medium_lines, function()
    luax.compile(medium_src, { dev_mode = true, inline_sourcemap = true, filename = "medium.luax" })
  end))

  table.insert(results, run_benchmark("Compile: Dev + SourceMap (Large)", 40, large_lines, function()
    luax.compile(large_src, { dev_mode = true, inline_sourcemap = true, filename = "large.luax" })
  end))

  -- 6. Formatter Pretty-Printing
  table.insert(results, run_benchmark("Formatter: CST Pretty-Print (Small)", 1500, small_lines, function()
    formatter.format(small_src)
  end))

  table.insert(results, run_benchmark("Formatter: CST Pretty-Print (Medium)", 400, medium_lines, function()
    formatter.format(medium_src)
  end))

  -- 7. LuaLS Virtual Lowering
  table.insert(results, run_benchmark("LuaLS Plugin: Virtual Lowering (Small)", 2000, small_lines, function()
    plugin.virtual_lower(small_src)
  end))

  table.insert(results, run_benchmark("LuaLS Plugin: Virtual Lowering (Medium)", 600, medium_lines, function()
    plugin.virtual_lower(medium_src)
  end))

  table.insert(results, run_benchmark("LuaLS Plugin: Virtual Lowering (Large)", 60, large_lines, function()
    plugin.virtual_lower(large_src)
  end))

  -- Print Formatted Output Table
  print(string.format("%-46s | %10s | %12s | %14s | %14s | %12s",
    "Benchmark Task", "Iterations", "Elapsed (ms)", "Throughput (l/s)", "Throughput (op/s)", "Avg Latency"))
  print(string.rep("-", 124))

  for _, res in ipairs(results) do
    local latency_str
    if res.avg_latency_us < 1.0 then
      latency_str = string.format("%.2f ns", res.avg_latency_us * 1000)
    elseif res.avg_latency_us < 1000.0 then
      latency_str = string.format("%.2f μs", res.avg_latency_us)
    else
      latency_str = string.format("%.2f ms", res.avg_latency_us / 1000)
    end

    print(string.format("%-46s | %10s | %12.2f | %14s | %14s | %12s",
      res.name,
      format_number(res.iterations),
      res.elapsed_ms,
      format_number(res.lines_per_sec),
      format_number(res.ops_per_sec),
      latency_str
    ))
  end

  print(string.rep("=", 124))
  print("All compiler benchmarks completed successfully.\n")
end

main()
