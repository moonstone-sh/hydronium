--[[
  Static `require` graph scanning, shared by every tool that needs "which
  modules does this code load": Ballad's client.resolve (bundling), the dev
  framework manifest (hydronium_dom.dev.client_manifest), Lab's DOM preview
  and dom/tools/gen_client_manifest.lua.

  A small Lua lexer, not a pattern match: comments and the contents of string
  literals are skipped, so `-- require("secret")` or a string that merely
  mentions a module never pulls it into a browser bundle. Only literal calls
  count -- `require("a.b")`, `require "a.b"`, or a long-bracket string -- and a
  computed `require(name)` is invisible here by design; Ballad's lexer-based
  require-discipline lint rejects those separately.
--]]

local M = {}

local function long_bracket(source, i)
  -- `[` at i; returns level and index after the opening bracket, or nil.
  local level = source:match("^%[(=*)%[", i)
  if not level then return nil end
  return #level, i + #level + 2
end

local function skip_long(source, after_open, level)
  local close = "]" .. string.rep("=", level) .. "]"
  local finish = source:find(close, after_open, true)
  if not finish then return #source + 1, source:sub(after_open) end
  return finish + #close, source:sub(after_open, finish - 1)
end

--- Literal module ids passed to `require`, in first-seen order, deduplicated.
--- @param source string
--- @return string[]
function M.literal_requires(source)
  local ids, seen = {}, {}
  local tokens = {} -- { kind = "name"|"string"|"punct", value }
  local i, n = 1, #source
  while i <= n do
    local ch = source:sub(i, i)
    if ch == "-" and source:sub(i + 1, i + 1) == "-" then
      local level, after = long_bracket(source, i + 2)
      if level then
        i = skip_long(source, after, level)
      else
        local eol = source:find("\n", i, true)
        i = eol and eol + 1 or n + 1
      end
    elseif ch == "\"" or ch == "'" then
      local j, parts = i + 1, {}
      while j <= n do
        local c = source:sub(j, j)
        if c == "\\" then
          parts[#parts + 1] = source:sub(j + 1, j + 1)
          j = j + 2
        elseif c == ch or c == "\n" then
          break
        else
          parts[#parts + 1] = c
          j = j + 1
        end
      end
      tokens[#tokens + 1] = { kind = "string", value = table.concat(parts) }
      i = j + 1
    elseif ch == "[" and long_bracket(source, i) then
      local level, after = long_bracket(source, i)
      local value
      i, value = skip_long(source, after, level)
      tokens[#tokens + 1] = { kind = "string", value = (value:gsub("^\n", "")) }
    elseif ch:match("[%a_]") then
      local name = source:match("^[%w_]+", i)
      tokens[#tokens + 1] = { kind = "name", value = name, dotted = source:sub(i - 1, i - 1) == "." or source:sub(i - 1, i - 1) == ":" }
      i = i + #name
    elseif ch:match("%s") then
      i = i + 1
    else
      tokens[#tokens + 1] = { kind = "punct", value = ch }
      i = i + 1
    end
  end
  for index, token in ipairs(tokens) do
    if token.kind == "name" and token.value == "require" and not token.dotted then
      local nxt = tokens[index + 1]
      if nxt and nxt.kind == "punct" and nxt.value == "(" then
        local arg, close = tokens[index + 2], tokens[index + 3]
        if not (arg and arg.kind == "string" and close and close.value == ")") then nxt = nil else nxt = arg end
      end
      if nxt and nxt.kind == "string" and nxt.value:match("^[%w_%.%-]+$") and not seen[nxt.value] then
        seen[nxt.value] = true
        ids[#ids + 1] = nxt.value
      end
    end
  end
  return ids
end

--- Breadth-first closure over the literal require graph.
--- @param seeds string[] module ids to start from
--- @param load fun(id: string): string|nil source for an id, or nil to skip it
--- @param extra_sources? string[] source texts whose requires also seed the walk
--- @return string[] order module ids that loaded, in visit order
--- @return table<string,string> sources id -> source
function M.closure(seeds, load, extra_sources)
  local pending, seen, order, sources = {}, {}, {}, {}
  for _, id in ipairs(seeds or {}) do pending[#pending + 1] = id end
  for _, source in ipairs(extra_sources or {}) do
    for _, id in ipairs(M.literal_requires(source)) do pending[#pending + 1] = id end
  end
  local index = 1
  while index <= #pending do
    local id = pending[index]
    index = index + 1
    if not seen[id] then
      seen[id] = true
      local source = load(id)
      if source then
        order[#order + 1] = id
        sources[id] = source
        for _, dependency in ipairs(M.literal_requires(source)) do pending[#pending + 1] = dependency end
      end
    end
  end
  return order, sources
end

return M
