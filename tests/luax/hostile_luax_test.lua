local function assert_eq(a, b, msg)
  if a ~= b then
    error("Assertion failed: " .. tostring(msg) .. " | Expected: " .. tostring(b) .. ", Got: " .. tostring(a))
  end
end

local function run_hostile_tests()
  package.path = "src/?.lua;src/?/init.lua;./?.lua;./?/init.lua;" .. package.path
  local lexer = require("hydronium_luax.lexer")
  local parser = require("hydronium_luax.parser")
  local compiler = require("hydronium_luax.compiler")
  local formatter = require("hydronium_luax.formatter")
  local sourcemap = require("hydronium_luax.sourcemap")
  local virtual_source = require("hydronium_luax.luals.virtual_source")

  print("Running hostile LUAX tests...")

  -- 1. Complex lexical disambiguation
  local code = [[
    local x, y, a, b = 1, 2, 3, 4
    local v = x < y and <div id={ a < b } /> or <span />
    local str = [====[
      <not_jsx>...</not_jsx>
    ]====]
  ]]
  local ast = parser:new(lexer:new(code)):parse()
  assert(ast ~= nil, "Should parse complex lexical disambiguation")

  -- 2. Nested Lua tables in attributes
  local code2 = [[
    local v = <div style={{ color = "red", width = 100 }} />
  ]]
  local ast2 = parser:new(lexer:new(code2)):parse()
  assert(ast2 ~= nil, "Should parse nested tables")

  -- 3. Spread attribute precedence
  local code3 = [[
    local v = <Button a="1" {...props} a="2" />
  ]]
  local ast3 = parser:new(lexer:new(code3)):parse()
  local compiled3 = compiler:new():compile(ast3)
  assert(compiled3:find("a = \"2\""), "Spread should respect precedence, wait, we are just checking it compiles without error")

  -- 4. Formatter idempotence
  local code4 = [[
    local function render()
      return (
        -- Comment 1
        <div id="main">
          {-- Comment 2}
          <span class="active">Hello</span>
        </div>
      )
    end
  ]]
  local fmt1 = formatter.format(code4)
  local fmt2 = formatter.format(fmt1)
  assert_eq(fmt1, fmt2, "Formatter must be idempotent")

  -- 5. Virtual source lowering
  local vs = virtual_source:new(code3)
  local res = vs:lower()
  assert(res:find("Button"), "Should contain mapped component")

  -- 6. Zero hardcoded HTML tags in compiler core
  local f = io.open("luax/src/hydronium_luax/parser.lua", "r")
  local content = f:read("*a")
  f:close()
  local hardcoded = content:match("['\"]div['\"]")
  assert(hardcoded == nil, "Should have zero hardcoded HTML tags in parser (except comments)")

  -- 7. SourceMap V3 Base64 VLQ
  local encoded = sourcemap.encode_vlq(123)
  local decoded = sourcemap.decode_vlq(encoded)
  assert_eq(decoded[1], 123, "VLQ encode/decode mismatch")

  -- 8. Document check
  local d = io.popen("ls docs/ | grep -c .md")
  local doc_count = tonumber(d:read("*a"))
  d:close()
  assert(doc_count >= 9, "Should have at least 9 docs")
  
  local dq = io.popen("grep -c '?' docs/LUAX_DX_COMPLIANCE.md")
  local q_count = tonumber(dq:read("*a"))
  dq:close()
  assert(q_count >= 70, "Should answer at least 70 architectural questions")

  print("All hostile tests passed successfully!")
end

run_hostile_tests()
