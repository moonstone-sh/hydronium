package.path = "src/?.lua;src/?/init.lua;" .. package.path
package.preload.pipeline_test_host = function()
  return {plan=function(input)
    assert(#input.paths == 1)
    return {files={[input.state_dir .. "/main.lua"]="return true\n"}, command="test-host"}
  end}
end
local ballad = require("ballad")
return ballad.partiture(function(p)
  local lab = p:use(require("hydronium_lab_cli.ballad"))
  local files = lab.prepare({state_dir=".hydronium/pipeline-test", config={roots={"tests/fixtures/pipeline"},host="pipeline_test_host",renderer="dom"}})
  p.sink.directory(files, {out=".hydronium/pipeline-test"})
end)
