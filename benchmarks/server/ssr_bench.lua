--[[
  Hydronium Server-Side Rendering (SSR) Benchmark Suite
  Measures microsecond latency, memory, and throughput (ops/sec) across:
  1. Small HTML Page Rendering
  2. 100 Component Tree with Scoped Props
  3. 1,000 Row Data Table Serialization
  4. Deep Tree (50+ Nested Levels with Context Propagation)
  5. String Concatenation vs Progressive Streaming Sink Comparison
--]]

package.path = "src/?.lua;src/?/init.lua;./?.lua;./?/init.lua;" .. package.path

local H = require("hydronium")

local function run_benchmark(name, iterations, fn)
  -- Warm-up
  local warmup_iters = math.min(10, math.max(1, math.floor(iterations * 0.05)))
  for _ = 1, warmup_iters do
    fn(1)
  end

  collectgarbage("collect")

  local start_time = os.clock()
  for i = 1, iterations do
    fn(i)
  end
  local end_time = os.clock()

  local elapsed_sec = end_time - start_time
  if elapsed_sec <= 0 then
    elapsed_sec = 0.000001
  end

  local elapsed_ms = elapsed_sec * 1000
  local ops_per_sec = iterations / elapsed_sec
  local avg_latency_us = (elapsed_sec / iterations) * 1000000

  return {
    name = name,
    iterations = iterations,
    elapsed_ms = elapsed_ms,
    ops_per_sec = ops_per_sec,
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

local function main()
  print("=========================================================================================")
  print("                  HYDRONIUM SERVER-SIDE RENDERING (SSR) BENCHMARK SUITE                  ")
  print("=========================================================================================")
  print(string.format("Lua Runtime: %s | Host: %s", _VERSION, package.config:sub(1, 1) == "/" and "macOS/Unix" or "Windows"))
  print("Measuring SSR execution throughput, latencies, and streaming performance...\n")

  local results = {}

  -- -------------------------------------------------------------------------
  -- 1. Small Page Rendering
  -- -------------------------------------------------------------------------
  local function SmallPage()
    return H.h("div", { class = "page-container" },
      H.h("header", { class = "navbar" },
        H.h("h1", nil, "Hydronium Web"),
        H.h("nav", nil,
          H.h("a", { href = "/" }, "Home"),
          H.h("a", { href = "/docs" }, "Docs"),
          H.h("a", { href = "/about" }, "About")
        )
      ),
      H.h("main", { class = "content" },
        H.h("h2", nil, "High Performance Lua Reactive Framework"),
        H.h("p", nil, "Hydronium provides sub-millisecond SSR latencies on standard hardware."),
        H.h("button", { type = "button", disabled = false, class = "btn btn-primary" }, "Get Started")
      ),
      H.h("footer", nil, "Copyright 2026 Hydronium")
    )
  end

  table.insert(results, run_benchmark("1. Small Page SSR (render_to_string)", 5000, function()
    local html = H.server.render_to_string(H.h(SmallPage))
  end))

  -- -------------------------------------------------------------------------
  -- 2. 100 Component Tree
  -- -------------------------------------------------------------------------
  local function Card(props)
    return H.h("div", { class = "card " .. (props.highlight and "active" or "normal") },
      H.h("h3", nil, props.title),
      H.h("p", nil, props.description),
      H.h("span", { class = "badge" }, "Index: " .. tostring(props.index))
    )
  end

  local function CardGrid()
    local cards = {}
    for i = 1, 100 do
      table.insert(cards, H.h(Card, {
        index = i,
        title = "Component Card #" .. i,
        description = "Scoped component description for card " .. i,
        highlight = (i % 5 == 0),
      }))
    end
    return H.h("section", { class = "grid" }, cards)
  end

  table.insert(results, run_benchmark("2. 100 Component Tree SSR (with Scope & Props)", 500, function()
    local html = H.server.render_to_string(H.h(CardGrid))
  end))

  -- -------------------------------------------------------------------------
  -- 3. 1,000 Row Data Table
  -- -------------------------------------------------------------------------
  local sample_rows = {}
  for i = 1, 1000 do
    table.insert(sample_rows, {
      id = i,
      name = "User " .. i,
      email = "user_" .. i .. "@example.com",
      status = (i % 2 == 0) and "Active" or "Pending",
      score = i * 1.5,
    })
  end

  local function LargeTable()
    local trs = {}
    for _, row in ipairs(sample_rows) do
      table.insert(trs, H.h("tr", { class = (row.id % 2 == 0) and "even" or "odd" },
        H.h("td", nil, row.id),
        H.h("td", nil, row.name),
        H.h("td", nil, row.email),
        H.h("td", nil, row.status),
        H.h("td", nil, row.score)
      ))
    end
    return H.h("table", { class = "data-table" },
      H.h("thead", nil,
        H.h("tr", nil,
          H.h("th", nil, "ID"),
          H.h("th", nil, "Name"),
          H.h("th", nil, "Email"),
          H.h("th", nil, "Status"),
          H.h("th", nil, "Score")
        )
      ),
      H.h("tbody", nil, trs)
    )
  end

  table.insert(results, run_benchmark("3. 1,000 Row Table SSR (Attributes & Escaping)", 100, function()
    local html = H.server.render_to_string(H.h(LargeTable))
  end))

  -- -------------------------------------------------------------------------
  -- 4. Deep Tree (50 Nested Levels with Context Propagation)
  -- -------------------------------------------------------------------------
  local DepthContext = H.createContext("RootContext")

  local function DeepLeaf()
    local ctx = H.useContext(DepthContext)
    return H.h("span", { class = "leaf" }, "Leaf with " .. tostring(ctx))
  end

  local function build_deep_tree(levels)
    local node = H.h(DeepLeaf)
    for l = levels, 1, -1 do
      node = H.h("div", { class = "level-" .. l, ["data-depth"] = l }, node)
    end
    return H.h(DepthContext.Provider, { value = "InheritedDeepContext" }, node)
  end

  local deep_tree = build_deep_tree(50)

  table.insert(results, run_benchmark("4. Deep Tree (50 Nested Levels + Context)", 1000, function()
    local html = H.server.render_to_string(deep_tree)
  end))

  -- -------------------------------------------------------------------------
  -- 5. String vs Streaming Sink Comparison (1,000 Item List)
  -- -------------------------------------------------------------------------
  local function StreamDoc()
    local items = {}
    for i = 1, 1000 do
      table.insert(items, H.h("li", { id = "item-" .. i }, "Stream Item #" .. i))
    end
    return H.h("ul", { class = "stream-list" }, items)
  end

  local stream_vnode = H.h(StreamDoc)

  -- 5a. Monolithic String render_to_string
  table.insert(results, run_benchmark("5a. 1,000 Items: Monolithic render_to_string", 100, function()
    local str = H.server.render_to_string(stream_vnode)
  end))

  -- 5b. Callable Streaming Sink
  table.insert(results, run_benchmark("5b. 1,000 Items: Callable Streaming Sink", 100, function()
    local chunks_count = 0
    H.server.render_to_stream(stream_vnode, function(chunk)
      chunks_count = chunks_count + 1
    end)
  end))

  -- 5c. Object Streaming Sink with :write(chunk)
  local mock_sink = {
    bytes = 0,
    write = function(self, chunk)
      self.bytes = self.bytes + #chunk
    end,
  }

  table.insert(results, run_benchmark("5c. 1,000 Items: Object Sink with :write", 100, function()
    mock_sink.bytes = 0
    H.server.render(stream_vnode, mock_sink)
  end))

  -- Print Formatted Results
  print("\n" .. string.rep("-", 105))
  print(string.format("%-52s | %10s | %14s | %16s", "Benchmark Scenario", "Iterations", "Avg Latency", "Throughput"))
  print(string.rep("-", 105))

  for _, res in ipairs(results) do
    print(string.format(
      "%-52s | %10s | %11.2f µs | %12s ops/s",
      res.name,
      format_number(res.iterations),
      res.avg_latency_us,
      format_number(res.ops_per_sec)
    ))
  end
  print(string.rep("-", 105))
  print("\n✓ All SSR benchmarks completed successfully.")
end

main()
