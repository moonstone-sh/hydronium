package.path = "src/?.lua;src/?/init.lua;../lab/src/?.lua;../lab/src/?/init.lua;" .. package.path

local adapter = require("hydronium_meteorite.lab_host")
local plan = adapter.plan({
  config = { roots = { "src", "features" }, module_roots = { "src", "shared" }, base_path = "/tools/lab" },
  config_path = ".hydronium/lab/config.lua",
  state_dir = ".hydronium/lab",
  paths = { "src/Status.stories.lua" },
  host = "127.0.0.1",
  port = 6200,
})

assert(plan.url == "http://127.0.0.1:6200/tools/lab/")
assert(plan.command:find("--hybrid-profile single_owner", 1, true))
assert(plan.environment.LUA_PATH:find("hydronium/lab/src/?.lua", 1, true))
assert(plan.environment.LUA_PATH:find("shared/?.lua", 1, true))
assert(plan.environment.LUA_CPATH:find("lua%-cjson") or plan.environment.LUA_CPATH:find("lua_cjson"))
local main = assert(plan.files[".hydronium/lab/main.lua"])
assert(main:find("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_LAB", 1, true))
assert(main:find("MOONSTONE_PACKAGE_ROOT_LUA_CJSON", 1, true))
assert(main:find('require("hydronium_meteorite.lab")', 1, true))
assert(main:find("lab.mount(app", 1, true))
assert(main:find('base_path = "/tools/lab"', 1, true))
assert(not main:find("app:get", 1, true), "route ownership must remain in the adapter")

package.loaded["hydronium_ink_lab"] = { service = {} }
local mounted = require("hydronium_meteorite.lab")
local routes = {}
local app = {}
for _, method in ipairs({ "get", "post", "delete" }) do
  app[method] = function(_, path, ...)
    routes[#routes + 1] = { method = method, path = path, args = { ... } }
  end
end
local contract = mounted.mount(app, { base_path = "/custom/lab", redirect_root = false })
assert(contract.assets.workbench_stylesheet == "/custom/lab/assets/workbench.css")
assert(contract.assets.workbench_client == "/custom/lab/assets/workbench.js")
assert(contract.assets.renderer_stylesheet == "/custom/lab/assets/ink.css")
local found = {}
for _, route in ipairs(routes) do found[route.method .. " " .. route.path] = true end
assert(found["get /custom/lab/"])
assert(found["get /custom/lab/assets/workbench.css"])
assert(found["get /custom/lab/assets/workbench.js"])
assert(found["get /custom/lab/assets/ink.css"])
assert(found["get /custom/lab/catalog"])
assert(found["post /custom/lab/sessions"])
assert(found["post /custom/lab/sessions/:id/operations"])
assert(found["delete /custom/lab/sessions/:id"])
assert(not found["get /"])
mounted.reset_for_test()

local invalid_base = pcall(adapter.plan, {
  config = { roots = { "src" }, base_path = "/tools/../admin" },
  config_path = ".hydronium/lab/config.lua",
  state_dir = ".hydronium/lab",
  paths = { "src/Status.stories.lua" },
  host = "127.0.0.1",
  port = 6200,
})
assert(not invalid_base, "the adapter must reject an invalid mount prefix while planning")

print("hydronium_meteorite.lab_host: ok")
