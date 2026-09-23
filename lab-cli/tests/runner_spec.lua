package.path = "src/?.lua;src/?/init.lua;../meteorite/src/?.lua;../meteorite/src/?/init.lua;" .. package.path

local runner = require("hydronium_lab_cli.runner")

local tree = {
  src = "directory",
  ["src/components"] = "directory",
  ["src/components/Input.stories.luax"] = "file",
  ["src/Status.stories.lua"] = "file",
  ["src/not-a-story.lua"] = "file",
  ["src/outside"] = "link",
}
local children = {
  src = { "not-a-story.lua", "outside", "components", "Status.stories.lua" },
  ["src/components"] = { "Input.stories.luax" },
}
local fs = {
  mode = function(path) return tree[path] end,
  entries = function(path) return children[path] end,
}

local paths = assert(runner.scan({ roots = { "src" } }, fs))
assert(#paths == 2)
assert(paths[1] == "src/Status.stories.lua")
assert(paths[2] == "src/components/Input.stories.luax")

package.preload["test_lab_host"] = function()
  return { plan = function(input)
    return { files = { [input.state_dir .. "/main.lua"] = "return true\n" }, command = "test-host", url = "http://test/lab/" }
  end }
end

local original_read = runner.read_config
runner.read_config = function()
  return { roots = { "src" }, title = "Test", project_name = "test", project_id = "test", host = "test_lab_host", base_path = "/lab" }
end
local plan = assert(runner.plan({ fs = fs, dry_run = true }))
runner.read_config = original_read
assert(plan.adapter == "test_lab_host")
assert(plan.command == "test-host")
assert(plan.files[".hydronium/lab/config.lua"]:find('base_path = "/lab"', 1, true))

local env_command = runner.command_with_environment("test-host", { LUA_PATH = "one;two", LAB_VALUE = "has a space" })
assert(env_command:find("test%-host"))
assert(env_command:find("LUA_PATH", 1, true))
assert(env_command:find("has a space", 1, true))

local invalid = runner.scan({ roots = { "../outside" } }, fs)
assert(invalid == nil, "escaping root must fail")

local overlapping, overlap_err = runner.scan({ roots = { "src", "src/components" } }, fs)
assert(overlapping == nil and overlap_err:find("overlap", 1, true), "overlapping roots must fail before enumeration")

local linked_root, linked_err = runner.scan({ roots = { "linked" } }, {
  mode = function() return "link" end,
  entries = function() return {} end,
})
assert(linked_root == nil and linked_err:find("symbolic link", 1, true), "a symlink root must not escape containment")

local hostile, hostile_err = runner.scan({ roots = { "src" } }, {
  mode = function(path) return path == "src" and "directory" or "file" end,
  entries = function() return { "../Outside.stories.lua" } end,
})
assert(hostile == nil and hostile_err:find("invalid entry", 1, true), "enumerator entries must remain basenames")

print("hydronium_lab_cli.runner: ok")
