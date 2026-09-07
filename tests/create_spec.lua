package.path = "./src/?.lua;./src/?/init.lua;" .. package.path

local create = require("create.init")
local luals = require("create.luals")

local total = 0
local passed = 0

local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  ✓ " .. name)
  else
    print("  ✗ " .. name)
    print("    Error: " .. tostring(err))
  end
end

print("\n--- hydronium-create unit tests ---")

test("available_templates lists all supported templates", function()
  local tmpls = create.available_templates()
  assert(#tmpls == 4, "expected 4 templates, got " .. #tmpls)
  local ids = {}
  for _, t in ipairs(tmpls) do
    ids[t.id] = true
  end
  assert(ids.ssr, "missing ssr template")
  assert(ids.islands, "missing islands template")
  assert(ids.spa, "missing spa template")
  assert(ids.minimal, "missing minimal template")
end)

test("scaffold dry-run produces expected files for ssr template", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-app",
    template = "ssr",
    name = "test-ssr-app",
    dry_run = true,
  })
  assert(res ~= nil, "scaffold returned nil: " .. tostring(err))
  assert(res.project_name == "test-ssr-app")
  assert(res.template == "ssr")
  
  local file_map = {}
  for _, f in ipairs(res.created) do
    file_map[f.path] = true
  end
  assert(file_map["moonstone.toml"], "missing moonstone.toml")
  assert(file_map["src/main.lua"], "missing src/main.lua")
  assert(file_map["views/App.luax"], "missing views/App.luax")
  assert(file_map["public/style.css"], "missing public/style.css")
end)

test("scaffold dry-run produces expected files for islands template", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-hydronium-islands",
    template = "islands",
    name = "test-islands-app",
    dry_run = true,
  })
  assert(res ~= nil, "scaffold returned nil: " .. tostring(err))
  local file_map = {}
  for _, f in ipairs(res.created) do
    file_map[f.path] = true
  end
  assert(file_map["views/Counter.luax"], "missing views/Counter.luax")
  assert(file_map["views/App.luax"], "missing views/App.luax")
end)

test("scaffold rejects invalid template name", function()
  local res, err = create.scaffold({
    directory = "/tmp/test-invalid",
    template = "non-existent-template",
    dry_run = true,
  })
  assert(res == nil, "expected error for unknown template")
  assert(err:find("Unknown template"), "expected Unknown template error message")
end)

test("luals.configure uses alter to update .luarc.json with Hydronium LuaX plugin", function()
  local tmp_dir = os.tmpname()
  os.remove(tmp_dir)
  os.execute(string.format('mkdir -p "%s"', tmp_dir))

  local res, err = luals.configure(tmp_dir, {
    interpreter = "lua@5.4",
  })
  assert(res ~= nil, "luals.configure failed: " .. tostring(err))
  assert(res.changed == true, "expected changed to be true")

  local f = io.open(tmp_dir .. "/.luarc.json", "r")
  assert(f ~= nil, "could not open generated .luarc.json")
  local content = f:read("*a")
  f:close()

  assert(content:find("hydronium/luax/luals/init.lua"), "missing hydronium plugin in .luarc.json")
  assert(content:find("%.moonstone/env/share/lua/5.4"), "missing workspace library in .luarc.json")
  assert(content:find("%*%.luax"), "missing *.luax association in .luarc.json")

  -- Idempotency check: running again should succeed without redundant duplicates
  local res2, err2 = luals.configure(tmp_dir, {
    interpreter = "lua@5.4",
  })
  assert(res2 ~= nil, "idempotent luals.configure failed: " .. tostring(err2))

  os.execute(string.format('rm -rf "%s"', tmp_dir))
end)

print(string.format("\nResults: %d/%d passed\n", passed, total))
if passed < total then
  os.exit(1)
end
