-- create's template floors and the CLIs' reported versions must equal the
-- member manifests (tools/version.lua; docs/VERSIONING.md). Lockstep across
-- members is enforced at release time by the release workflow.
local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert
local versions = require("tools.version")

describe("workspace versions", function()
  it("finds every workspace member and the workspace version", function()
    local members, workspace = versions.members(".")
    assert.truthy(#members > 10, "expected the orbit members, got " .. #members)
    assert.truthy(workspace and workspace:match("^%d+%.%d+%.%d+$"), tostring(workspace))
  end)

  it("keeps create's floors and the CLI versions equal to the members", function()
    local problems = versions.check(".")
    assert.equal(#problems, 0, table.concat(problems, "\n"))
  end)
end)
