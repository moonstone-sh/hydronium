-- Bridge Ballad's isolated tool scope to the installed Lab CLI planner.
local function prepare(ctx, inputs, opts)
  local root = os.getenv("MOONSTONE_PACKAGE_ROOT_HYDRONIUM_LAB_CLI")
  if root and root ~= "" then
    local payload = root .. "/libexec/hydronium-lab-cli"
    package.path = table.concat({payload .. "/src/?.lua", payload .. "/src/?/init.lua", payload .. "/lua/?.lua", payload .. "/lua/?/init.lua", root .. "/src/?.lua", root .. "/src/?/init.lua", root .. "/?.lua", root .. "/?/init.lua", package.path}, ";")
    package.cpath = table.concat({payload .. "/lib/?.so", payload .. "/lib/?.dylib", payload .. "/lib/?.dll", package.cpath}, ";")
  end
  local ok, planner = pcall(require, "hydronium_lab_cli.ballad")
  if not ok then ctx.fail("Lab pipeline preparation requires hydronium/lab-cli in the tool profile: " .. tostring(planner)) end
  return planner.prepare(ctx, inputs, opts)
end
return {
  name="hydronium_ballad.plugins.lab", version="0.1.0",
  methods={prepare={inputs={},outputs={"asset_set"},cacheable=false,parallel_safe=false}},
  prepare=prepare,
}
