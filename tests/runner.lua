-- Hydronium Test Harness and Runner
-- The repository root is an orbits workspace, not a package.  Test the
-- member source roots explicitly; external-consumer coverage below verifies
-- Moonstone materialization separately.
package.path = "core/src/?.lua;core/src/?/init.lua;luax/src/?.lua;luax/src/?/init.lua;dom/src/?.lua;dom/src/?/init.lua;ink/src/?.lua;ink/src/?/init.lua;./?.lua;./?/init.lua;" .. package.path

local M = {}
package.loaded["tests.runner"] = M
package.loaded["runner"] = M
package.loaded["tests.runner"] = M

local describe_stack = {}
local before_each_stack = {}
local after_each_stack = {}
local tests = {}
local current_file = ""

local stats = {
  total = 0,
  passed = 0,
  failed = 0,
  skipped = 0,
  start_time = 0,
  end_time = 0,
}

-- Deep comparison for tables
local function deep_equal(a, b, visited)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end

  visited = visited or {}
  if visited[a] and visited[a] == b then return true end
  visited[a] = b

  -- Compare all keys in a
  for k, v in pairs(a) do
    if b[k] == nil and v ~= nil then return false end
    if not deep_equal(v, b[k], visited) then return false end
  end

  -- Check if b has extra keys
  for k, v in pairs(b) do
    if a[k] == nil and v ~= nil then return false end
  end

  return true
end

local function dump_val(v, depth)
  depth = depth or 0
  if depth > 3 then return "..." end
  if type(v) == "string" then
    return string.format("%q", v)
  elseif type(v) == "table" then
    local parts = {}
    local is_arr = true
    local max_idx = 0
    for k, _ in pairs(v) do
      if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
        is_arr = false
      else
        if k > max_idx then max_idx = k end
      end
    end

    if is_arr and max_idx > 0 then
      for i = 1, math.min(max_idx, 10) do
        table.insert(parts, dump_val(v[i], depth + 1))
      end
      if max_idx > 10 then table.insert(parts, "...") end
      return "{" .. table.concat(parts, ", ") .. "}"
    else
      local count = 0
      for k, val in pairs(v) do
        count = count + 1
        if count > 8 then
          table.insert(parts, "...")
          break
        end
        table.insert(parts, tostring(k) .. " = " .. dump_val(val, depth + 1))
      end
      return "{" .. table.concat(parts, ", ") .. "}"
    end
  else
    return tostring(v)
  end
end

-- Assertions
local assert_lib = {}

function assert_lib.equal(actual, expected, msg)
  if actual ~= expected then
    local err = string.format("Assertion failed: expected %s, got %s%s",
      dump_val(expected), dump_val(actual), msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

function assert_lib.not_equal(actual, expected, msg)
  if actual == expected then
    local err = string.format("Assertion failed: expected value to not equal %s%s",
      dump_val(expected), msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

function assert_lib.same(actual, expected, msg)
  if not deep_equal(actual, expected) then
    local err = string.format("Assertion failed (deep equality):\nExpected: %s\nActual:   %s%s",
      dump_val(expected), dump_val(actual), msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

function assert_lib.truthy(val, msg)
  if not val then
    local err = string.format("Assertion failed: expected truthy value, got %s%s",
      dump_val(val), msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

function assert_lib.falsy(val, msg)
  if val then
    local err = string.format("Assertion failed: expected falsy value, got %s%s",
      dump_val(val), msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

--- Unconditionally fails with the given message. Found missing
--- (tests/luax/isolation_spec.lua called it and got a confusing "attempt
--- to call field 'fail'" instead of the intended pollution-detected
--- message) while adding tests/interpreter/lua_spec.lua.
function assert_lib.fail(msg)
  error("Assertion failed: " .. tostring(msg), 2)
end

function assert_lib.is_nil(val, msg)
  if val ~= nil then
    local err = string.format("Assertion failed: expected nil, got %s%s",
      dump_val(val), msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

function assert_lib.is_not_nil(val, msg)
  if val == nil then
    local err = string.format("Assertion failed: expected non-nil value, got nil%s",
      msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

function assert_lib.is_table(val, msg)
  if type(val) ~= "table" then
    local err = string.format("Assertion failed: expected table, got %s%s",
      type(val), msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

function assert_lib.is_string(val, msg)
  if type(val) ~= "string" then
    local err = string.format("Assertion failed: expected string, got %s%s",
      type(val), msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

function assert_lib.is_number(val, msg)
  if type(val) ~= "number" then
    local err = string.format("Assertion failed: expected number, got %s%s",
      type(val), msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

function assert_lib.is_boolean(val, msg)
  if type(val) ~= "boolean" then
    local err = string.format("Assertion failed: expected boolean, got %s%s",
      type(val), msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

function assert_lib.is_function(val, msg)
  if type(val) ~= "function" then
    local err = string.format("Assertion failed: expected function, got %s%s",
      type(val), msg and (" (" .. msg .. ")") or "")
    error(err, 2)
  end
end

function assert_lib.has_error(fn, pattern, msg)
  local ok, err = pcall(fn)
  if ok then
    local m = string.format("Assertion failed: expected function to error, but it succeeded%s",
      msg and (" (" .. msg .. ")") or "")
    error(m, 2)
  end
  if pattern then
    local err_str = tostring(err)
    if not string.find(err_str, pattern, 1, true) and not string.match(err_str, pattern) then
      local m = string.format("Assertion failed: error '%s' did not match expected pattern '%s'%s",
        err_str, pattern, msg and (" (" .. msg .. ")") or "")
      error(m, 2)
    end
  end
end

M.assert = assert_lib

-- Test structuring
function M.describe(name, fn)
  table.insert(describe_stack, name)
  local ok, err = pcall(fn)
  table.remove(describe_stack)
  if not ok then
    error(err, 2)
  end
end

function M.before_each(fn)
  local level = #describe_stack
  if not before_each_stack[level] then
    before_each_stack[level] = {}
  end
  table.insert(before_each_stack[level], fn)
end

function M.after_each(fn)
  local level = #describe_stack
  if not after_each_stack[level] then
    after_each_stack[level] = {}
  end
  table.insert(after_each_stack[level], fn)
end

function M.it(name, fn)
  local full_name = table.concat(describe_stack, " > ") .. " > " .. name

  -- Capture before_each and after_each hooks active for this test
  local be_hooks = {}
  for i = 1, #describe_stack do
    if before_each_stack[i] then
      for _, h in ipairs(before_each_stack[i]) do
        table.insert(be_hooks, h)
      end
    end
  end

  local ae_hooks = {}
  for i = #describe_stack, 1, -1 do
    if after_each_stack[i] then
      for _, h in ipairs(after_each_stack[i]) do
        table.insert(ae_hooks, h)
      end
    end
  end

  table.insert(tests, {
    name = full_name,
    file = current_file,
    fn = fn,
    before_each = be_hooks,
    after_each = ae_hooks,
  })
end

M.test = M.it

-- Globals for convenience when writing specs
_G.describe = M.describe
_G.it = M.it
_G.test = M.it
_G.before_each = M.before_each
_G.after_each = M.after_each
_G.assert = M.assert

local function run_single_test(t)
  local start_t = os.clock()

  -- Run before_each hooks
  for _, h in ipairs(t.before_each) do
    local ok, err = pcall(h)
    if not ok then
      local duration = (os.clock() - start_t) * 1000
      return false, "before_each hook failed: " .. tostring(err), duration
    end
  end

  -- Run test body
  local test_ok, test_err = pcall(t.fn)

  -- Run after_each hooks regardless
  local hook_err = nil
  for _, h in ipairs(t.after_each) do
    local ok, err = pcall(h)
    if not ok and not hook_err then
      hook_err = "after_each hook failed: " .. tostring(err)
    end
  end

  local duration = (os.clock() - start_t) * 1000

  if not test_ok then
    return false, test_err, duration
  elseif hook_err then
    return false, hook_err, duration
  else
    return true, nil, duration
  end
end

function M.run_all()
  local colors = {
    green = "\27[32m",
    red = "\27[31m",
    yellow = "\27[33m",
    cyan = "\27[36m",
    bold = "\27[1m",
    reset = "\27[0m",
  }

  print(string.format("%s%s=== Running Hydronium Test Suite (%d tests) ===%s\n",
    colors.bold, colors.cyan, #tests, colors.reset))

  stats.total = #tests
  stats.start_time = os.clock()

  local failures = {}

  for i, t in ipairs(tests) do
    local ok, err, dur = run_single_test(t)
    if ok then
      stats.passed = stats.passed + 1
      print(string.format("  %s✓ PASS%s %s %s(%.2f ms)%s",
        colors.green, colors.reset, t.name, colors.cyan, dur, colors.reset))
    else
      stats.failed = stats.failed + 1
      print(string.format("  %s✗ FAIL%s %s %s(%.2f ms)%s",
        colors.red, colors.reset, t.name, colors.cyan, dur, colors.reset))
      table.insert(failures, {
        test = t,
        error = err,
      })
    end
  end

  stats.end_time = os.clock()
  local total_sec = stats.end_time - stats.start_time

  print("\n" .. string.rep("=", 60))
  if #failures > 0 then
    print(string.format("%s%sFAILURES (%d):%s", colors.bold, colors.red, #failures, colors.reset))
    for i, f in ipairs(failures) do
      print(string.format("\n%d) %s%s%s\n   %s", i, colors.bold, f.test.name, colors.reset, tostring(f.error)))
    end
    print("\n" .. string.rep("=", 60))
  end

  local summary_color = stats.failed == 0 and colors.green or colors.red
  print(string.format("%s%sSUMMARY: %d Total | %d Passed | %d Failed | Duration: %.3f s%s\n",
    colors.bold, summary_color, stats.total, stats.passed, stats.failed, total_sec, colors.reset))

  return stats.failed == 0
end

local is_running = false

-- CLI execution
local function main()
  if is_running then return end
  is_running = true

  local files = {}

  if #arg > 0 then
    for _, f in ipairs(arg) do
      table.insert(files, f)
    end
  else
    -- Default spec list
    files = {
      -- Core framework specs
      "tests/signals/signals_spec.lua",
      "tests/core/element_spec.lua",
      "tests/core/dom_descriptors_spec.lua",
      "tests/core/component_spec.lua",
      "tests/core/reconciler_spec.lua",
      "tests/core/context_ref_spec.lua",
      "tests/core/error_spec.lua",
      "tests/core/refresh_spec.lua",
      "tests/core/refresh_component_spec.lua",
      "tests/core/family_hmr_spec.lua",
      "tests/core/hydration_spec.lua",
      "tests/core/family_identity_adversarial_spec.lua",
      "tests/host/dom_spec.lua",
      "tests/host/terminal_spec.lua",
      "tests/core/lua_mount_spec.lua",
      "tests/core/lazy_barrel_spec.lua",
      "tests/luax/no_core_coupling_spec.lua",
      "tests/test_renderer/test_renderer_spec.lua",
      -- Server renderer specs
      "tests/server/ssr_spec.lua",
      "tests/server/server_spec.lua",
      "tests/server/islands_suspense_spec.lua",
      "tests/server/meteorite_spec.lua",
      "tests/interpreter/lua_spec.lua",
      "tests/meteorite/meteorite_integration_spec.lua",
      -- LUAX compiler & tooling specs
      "tests/luax/lexer_spec.lua",
      "tests/luax/parser_spec.lua",
      "tests/luax/compiler_spec.lua",
      "tests/luax/spread_spec.lua",
      "tests/luax/lowerer_spec.lua",
      "tests/luax/sourcemap_spec.lua",
      "tests/luax/multi_runtime_spec.lua",
      "tests/luax/formatter_spec.lua",
      "tests/luax/luals_plugin_spec.lua",
      "tests/luax/virtual_source_spec.lua",
      "tests/luax/type_declarations_spec.lua",
      "tests/luax/isolation_spec.lua",
      "tests/luax/corpus_spec.lua",
      "tests/luax/environment_pragma_spec.lua",
    }
  end

  for _, file in ipairs(files) do
    current_file = file
    -- Reset stacks between files
    describe_stack = {}
    before_each_stack = {}
    after_each_stack = {}
    local chunk, load_err = loadfile(file)
    if not chunk then
      error("Failed to load test file " .. file .. ": " .. tostring(load_err))
    end
    chunk()
  end

  local success = M.run_all()
  if not success then
    os.exit(1)
  else
    os.exit(0)
  end
end

-- If executed directly via CLI
if arg and arg[0] and (string.match(arg[0], "runner%.lua$") or string.match(arg[0], "tests/runner")) then
  main()
end

return M
