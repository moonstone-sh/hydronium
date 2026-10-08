local h = require("tests.runner")
local virtual_source = require("hydronium_luax.luals.virtual_source")

local describe, it = h.describe, h.it
local assert = h.assert

-- Every .luax file in the repository must project to Lua that parses, or
-- lua-language-server checks a broken document (every diagnostic after the
-- break is noise). A projection change that breaks a real file fails here.
describe("LUAX LuaLS projection over the repository", function()
  it("projects every .luax file to valid Lua", function()
    local pipe = io.popen(
      "find . -name '*.luax' -not -path '*/node_modules/*' -not -path '*/.moonstone/*' -not -path '*/dist/*' -not -path './.git/*' | sort")
    assert.truthy(pipe, "could not list .luax files")
    local files, broken = 0, {}
    for path in pipe:lines() do
      local f = io.open(path, "rb")
      local source = f:read("*a")
      f:close()
      local virtual = virtual_source.transform(source, path)
      if virtual ~= source then -- an unparsable file comes back unchanged
        files = files + 1
        local ok, err = (loadstring or load)(virtual, "=" .. path)
        if not ok then broken[#broken + 1] = err end
      end
    end
    pipe:close()
    assert.truthy(files >= 20, "expected the repository's .luax files, found " .. files)
    assert.equal(#broken, 0, table.concat(broken, "\n"))
  end)
end)
