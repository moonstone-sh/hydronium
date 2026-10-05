-- Ballad adapter over the CLI's canonical discovery and host planner.
-- This prepares the host files; the pipeline never starts a long-lived server.
local M = {}

function M.prepare(ctx, _, opts)
  opts = opts or {}
  local runner = require("hydronium_lab_cli.runner")
  local state_dir = opts.state_dir or ".hydronium/lab"
  if type(state_dir) ~= "string" or state_dir:find("[%z\r\n]") then ctx.fail("Lab state_dir must be a path string") end
  if state_dir:sub(1,1) == "/" or state_dir:find("\\", 1, true) then ctx.fail("Lab state_dir must be project-relative") end
  for part in state_dir:gmatch("[^/]+") do
    if part == ".." or part == "." then ctx.fail("Lab state_dir cannot contain dot segments") end
  end
  state_dir = state_dir:gsub("/+$", "")
  if state_dir == "" then ctx.fail("Lab state_dir cannot be empty") end
  local plan, plan_error = runner.plan({config=opts.config or opts.config_path, state_dir=state_dir, port=opts.port, host=opts.host})
  if not plan then ctx.fail(plan_error) end
  local graph = require("ballad.graph")
  local assets = graph.AssetSet.new()
  local paths = {}
  for path in pairs(plan.files) do paths[#paths+1] = path end
  table.sort(paths)
  for _, path in ipairs(paths) do
    local prefix = state_dir .. "/"
    if path:sub(1,#prefix) ~= prefix then ctx.fail("Lab host output must remain inside state_dir: " .. path) end
    assets:add(ctx.graph:add_asset({kind="file", virtual_path=path:sub(#prefix+1), content=plan.files[path],
      metadata={lab={adapter=plan.adapter, command=plan.command, environment=plan.environment}}}))
  end
  return assets
end

return {
  name="hydronium_lab_cli.ballad", version="0.1.0",
  methods={prepare={inputs={}, outputs={"asset_set"}, cacheable=false, parallel_safe=false}},
  prepare=M.prepare,
}
