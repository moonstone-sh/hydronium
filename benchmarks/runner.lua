-- Hydronium Performance Benchmark Suite
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
  print("                       HYDRONIUM PERFORMANCE BENCHMARK SUITE                             ")
  print("=========================================================================================")
  print(string.format("Lua Runtime: %s | OS: %s", _VERSION, package.config:sub(1, 1) == "/" and "Unix/macOS" or "Windows"))
  print("Collecting performance metrics across core subsystems...\n")

  local results = {}

  -- 1. Element Creation
  table.insert(results, run_benchmark("Element creation (h / createElement)", 100000, function(i)
    local el = H.h("div", { id = "item_" .. i, class = "btn primary" },
      H.h("span", nil, "Label"),
      H.h("b", nil, i)
    )
  end))

  -- 2. Mounting Shallow Trees
  table.insert(results, run_benchmark("Mounting shallow tree (2,000 flat children)", 50, function()
    local children = {}
    for j = 1, 2000 do
      table.insert(children, H.h("div", { key = j, id = "c_" .. j }, "Child " .. j))
    end
    local root = H.create_test_root()
    root:render(H.h("div", { id = "container" }, children))
    root:unmount()
  end))

  -- 3. Mounting Deep Trees
  table.insert(results, run_benchmark("Mounting deep tree (100 nested levels)", 200, function()
    local node = "Leaf"
    for level = 100, 1, -1 do
      node = H.h("div", { level = level }, node)
    end
    local root = H.create_test_root()
    root:render(node)
    root:unmount()
  end))

  -- 4. Updating Unchanged Props
  do
    local root = H.create_test_root()
    local children = {}
    for j = 1, 500 do
      table.insert(children, H.h("span", { key = j, class = "static" }, "Text " .. j))
    end
    local tree = H.h("div", { id = "root" }, children)
    root:render(tree)

    table.insert(results, run_benchmark("Updating unchanged props (500 nodes)", 200, function()
      root:update(tree)
    end))
    root:unmount()
  end

  -- 5. Updating Changed Props
  do
    local root = H.create_test_root()
    local initialChildren = {}
    for j = 1, 500 do
      table.insert(initialChildren, H.h("span", { key = j, class = "initial" }, "Text " .. j))
    end
    root:render(H.h("div", nil, initialChildren))

    table.insert(results, run_benchmark("Updating changed props (500 nodes)", 200, function(i)
      local newChildren = {}
      for j = 1, 500 do
        table.insert(newChildren, H.h("span", { key = j, class = "updated_" .. i }, "Text " .. j))
      end
      root:update(H.h("div", nil, newChildren))
    end))
    root:unmount()
  end

  -- 6. Keyed Reorder
  do
    local root = H.create_test_root()
    local itemsForward = {}
    local itemsReversed = {}
    for j = 1, 500 do
      table.insert(itemsForward, H.h("li", { key = j, id = "li_" .. j }, j))
    end
    for j = 500, 1, -1 do
      table.insert(itemsReversed, H.h("li", { key = j, id = "li_" .. j }, j))
    end

    table.insert(results, run_benchmark("Keyed child reorder (500 items reversed)", 200, function(i)
      if i % 2 == 1 then
        root:render(H.h("ul", nil, itemsForward))
      else
        root:render(H.h("ul", nil, itemsReversed))
      end
    end))
    root:unmount()
  end

  -- 7. Signal Writes (Direct)
  do
    local sig, set_sig = H.signal(0)
    table.insert(results, run_benchmark("Signal writes (direct, unobserved)", 100000, function(i)
      set_sig(i)
    end))
  end

  -- 8. Batched Signal Writes
  do
    local s1, set_s1 = H.signal(0)
    local s2, set_s2 = H.signal(0)
    local s3, set_s3 = H.signal(0)

    table.insert(results, run_benchmark("Batched signal writes (3 signals x 10,000 batches)", 10000, function(i)
      H.batch(function()
        set_s1(i)
        set_s2(i * 2)
        set_s3(i * 3)
      end)
    end))
  end

  -- 9. Computed Propagation (Diamond Graph)
  do
    local source, set_source = H.signal(1)
    local left = H.computed(function() return source() * 2 end)
    local right = H.computed(function() return source() + 10 end)
    local diamond = H.computed(function() return left() + right() end)

    table.insert(results, run_benchmark("Computed propagation (diamond graph: S -> L, R -> D)", 10000, function(i)
      set_source(i)
      local val = diamond()
    end))
  end

  -- 10. Effect Scheduling & Execution
  do
    local trigger, set_trigger = H.signal(0)
    local effectRuns = 0
    local eff = H.effect(function()
      trigger()
      effectRuns = effectRuns + 1
    end)

    table.insert(results, run_benchmark("Effect execution on signal update", 10000, function(i)
      set_trigger(i)
    end))
    eff:dispose()
  end

  -- 11. Unmounting
  table.insert(results, run_benchmark("Unmounting tree (1,000 nodes with cleanups)", 100, function()
    local children = {}
    for j = 1, 1000 do
      table.insert(children, H.h("div", { key = j }, "Node " .. j))
    end
    local root = H.create_test_root()
    root:render(H.h("div", nil, children))
    root:unmount()
  end))

  -- Output formatted results
  print(string.format("%-55s | %10s | %12s | %16s | %12s",
    "Benchmark Task", "Iterations", "Elapsed (ms)", "Throughput (ops/s)", "Avg Latency"))
  print(string.rep("-", 120))

  for _, res in ipairs(results) do
    local latency_str
    if res.avg_latency_us < 1.0 then
      latency_str = string.format("%.2f ns", res.avg_latency_us * 1000)
    elseif res.avg_latency_us < 1000.0 then
      latency_str = string.format("%.2f μs", res.avg_latency_us)
    else
      latency_str = string.format("%.2f ms", res.avg_latency_us / 1000)
    end

    print(string.format("%-55s | %10s | %12.2f | %16s | %12s",
      res.name,
      format_number(res.iterations),
      res.elapsed_ms,
      format_number(res.ops_per_sec),
      latency_str
    ))
  end

  print(string.rep("=", 120))
  print("All benchmarks completed successfully.\n")
end

main()
