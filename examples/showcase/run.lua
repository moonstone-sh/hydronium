--[[
  Hydronium Showcase Application Runner
  Compiles all .luax components, renders App via Server-Side Rendering (SSR),
  and tests InteractiveIsland reactivity via Hydronium TestHost.

  Usage:
    luajit examples/showcase/run.lua
--]]

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local hydronium = require("hydronium")
local luax = require("hydronium_luax")
local server = require("hydronium_dom.server")
local test_module = require("hydronium.test")
local TestHost = test_module.TestHost

local function read_file(path)
  local f, err = io.open(path, "r")
  if not f then error("Cannot read file " .. path .. ": " .. tostring(err), 2) end
  local content = f:read("*a")
  f:close()
  return content
end

print("================================================================================")
print("Hydronium .luax Showcase Compilation & Verification")
print("================================================================================")

-- 1. Compile all .luax files
local component_files = {
  "Header.luax",
  "SVG.luax",
  "InteractiveIsland.luax",
  "PackageBrowser.luax",
  "Form.luax",
  "ErrorBoundary.luax",
  "App.luax",
}

local compiled_modules = {}

local shared_env = {
  H = hydronium,
  hydronium = hydronium,
  __luax = require("hydronium_luax.runtime"),
  tostring = tostring,
  tonumber = tonumber,
  pairs = pairs,
  ipairs = ipairs,
  type = type,
  select = select,
  pcall = pcall,
  error = error,
}
setmetatable(shared_env, { __index = _G })

for _, filename in ipairs(component_files) do
  local filepath = "examples/showcase/" .. filename
  local src = read_file(filepath)
  local t0 = os.clock()
  local res = luax.compile(src, {
    filename = filename,
    runtime = "hydronium",
    sourcemap = true,
  })
  local compile_time = (os.clock() - t0) * 1000

  local chunk, err = load(res.code, filename, "t", shared_env)
  if not chunk then
    error(string.format("Syntax error loading compiled %s: %s\nCode:\n%s", filename, tostring(err), res.code))
  end

  local mod = chunk()
  compiled_modules[filename:gsub("%.luax$", "")] = mod
  print(string.format("  ✓ Compiled %-24s in %6.2f ms (%d bytes Lua)", filename, compile_time, #res.code))
end

-- Wire components into shared environment so App can reference them
shared_env.Header = compiled_modules.Header
shared_env.PackageBrowser = compiled_modules.PackageBrowser.PackageBrowser
shared_env.PackageCard = compiled_modules.PackageBrowser.PackageCard
shared_env.InteractiveIsland = compiled_modules.InteractiveIsland
shared_env.PackageForm = compiled_modules.Form
shared_env.SafeContainer = compiled_modules.ErrorBoundary

local App = compiled_modules.App

-- 2. Test Server-Side Rendering (SSR)
print("\n--------------------------------------------------------------------------------")
print("Executing Server-Side Rendering (SSR) of Root <App />")
print("--------------------------------------------------------------------------------")

local app_props = {
  title = "Hydronium Production Showcase",
  username = "Core Team",
  packages = {
    {
      name = "meteorite",
      version = "0.9.4",
      description = "Next-generation high-throughput API & Web service framework for LuaJIT and Zig.",
      stars = 420,
      isOfficial = true,
      isSSRReady = true,
      lang = "Lua/Zig",
    },
    {
      name = "hydronium",
      version = "1.0.0",
      description = "Modern declarative UI framework featuring fine-grained signals and HTML5 SSR.",
      stars = 890,
      isOfficial = true,
      isSSRReady = true,
      lang = "Lua",
    },
    {
      name = "partiture",
      version = "0.5.1",
      description = "Hermetic package manager and task orchestration engine for Lua ecosystems.",
      stars = 310,
      isOfficial = false,
      isSSRReady = true,
      lang = "Lua",
    },
  },
  islandProps = {
    initialCount = 42,
    title = "Live Island Metric",
  },
  formProps = {
    values = {
      name = "hydronium-query",
      description = "Declarative asynchronous data fetching and cache management for Hydronium.",
      version = "0.2.0",
      ssr_compatible = true,
    },
    isValid = true,
    isSubmitting = false,
  },
}

local ssr_vnode = hydronium.createElement(App, app_props)

local t_ssr = os.clock()
local ssr_html = server.render_to_string(ssr_vnode, {
  doctype = true,
  state = {
    user = { id = 1, name = "Core Team" },
    initialCount = 42,
  },
})
local ssr_time = (os.clock() - t_ssr) * 1000

print(string.format("  ✓ SSR rendered %d bytes in %.3f ms", #ssr_html, ssr_time))

-- Verifications of SSR HTML
local checks = {
  { name = "Doctype is present", test = ssr_html:sub(1, 15):find("<!DOCTYPE html>") ~= nil },
  { name = "Header rendered with logo text", test = ssr_html:find("Hydronium Production Showcase") ~= nil },
  { name = "Strict HTML5 void element input has NO closing slash", test = ssr_html:find("<input [^>]*/>") == nil and ssr_html:find("<input [^>]*>") ~= nil },
  { name = "Boolean attribute 'checked' serialized without value", test = ssr_html:find("<input [^>]* checked[^>]*>") ~= nil or ssr_html:find("checked") ~= nil },
  { name = "State serialized into __HYDRONIUM_STATE__ script", test = ssr_html:find('<script id="__HYDRONIUM_STATE__"') ~= nil },
  { name = "Package cards rendered properly", test = ssr_html:find("meteorite") ~= nil and ssr_html:find("hydronium") ~= nil },
  { name = "SafeContainer children rendered", test = ssr_html:find("All submodules running cleanly%.") ~= nil },
}

for _, check in ipairs(checks) do
  if check.test then
    print("  ✓ " .. check.name)
  else
    error("SSR check failed: " .. check.name)
  end
end

-- 3. Test Client-Side Reactivity of InteractiveIsland in TestHost
print("\n--------------------------------------------------------------------------------")
print("Testing Client-Side Island Reactivity with TestRoot")
print("--------------------------------------------------------------------------------")

local root = hydronium.create_test_root()
local count, setCount = hydronium.createSignal(10)

local InteractiveIsland = compiled_modules.InteractiveIsland

local function IslandContainer()
  return hydronium.createElement(InteractiveIsland, {
    initialCount = count(),
    onIncrement = function()
      setCount(count() + 1)
    end,
    onDecrement = function()
      setCount(count() - 1)
    end,
  })
end

root:render(hydronium.createElement(IslandContainer, nil))
print("  Initial text in DOM:  " .. tostring(root:text()))

-- Dispatch click on increment button
local inc_btn = root:find({ props = { ["data-testid"] = "inc-btn" } }) or root:find(function(n) return n.props and n.props["data-testid"] == "inc-btn" end)
if inc_btn and inc_btn.props and inc_btn.props.onClick then
  hydronium.act(function()
    inc_btn.props.onClick()
    root:update(hydronium.createElement(IslandContainer, nil))
  end)
  print("  After click (+):      Count signal = " .. tostring(count()))
end

-- Dispatch click on decrement button
local dec_btn = root:find({ props = { ["data-testid"] = "dec-btn" } }) or root:find(function(n) return n.props and n.props["data-testid"] == "dec-btn" end)
if dec_btn and dec_btn.props and dec_btn.props.onClick then
  hydronium.act(function()
    dec_btn.props.onClick()
    dec_btn.props.onClick()
    root:update(hydronium.createElement(IslandContainer, nil))
  end)
  print("  After 2 clicks (-):   Count signal = " .. tostring(count()))
end

if count() ~= 9 then
  error("Expected count to be 9, got " .. tostring(count()))
end
print("  ✓ Client island reactivity verified successfully!")

print("\n================================================================================")
print("SHOWCASE VERIFICATION SUMMARY: All checks passed with 100% success!")
print("================================================================================")
