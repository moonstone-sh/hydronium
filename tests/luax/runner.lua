-- Hydronium LUAX Test Suite Runner
package.path = "src/?.lua;src/?/init.lua;./?.lua;./?/init.lua;" .. package.path

local runner = require("tests.runner")

local luax_specs = {
  "tests/luax/lexer_spec.lua",
  "tests/luax/parser_spec.lua",
  "tests/luax/compiler_spec.lua",
  "tests/luax/spread_spec.lua",
  "tests/luax/sourcemap_spec.lua",
  "tests/luax/formatter_spec.lua",
  "tests/luax/virtual_source_spec.lua",
}

for _, spec in ipairs(luax_specs) do
  local chunk, err = loadfile(spec)
  if not chunk then
    error("Failed to load " .. spec .. ": " .. tostring(err))
  end
  chunk()
end

local ok = runner.run_all()
if not ok then
  os.exit(1)
end
