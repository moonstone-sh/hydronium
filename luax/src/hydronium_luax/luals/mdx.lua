--[[
  hydronium_luax.luals.mdx -- the LuaLS view of a Markdown component module.

  LuaLS only understands Lua, so an `.mdx` (or `.md`) document is projected
  into a Lua document that keeps every piece of real code at its original
  byte position:

    `lua setup` fence contents  kept verbatim (module scope)
    `{expr}`                    `_(expr)`       -- `{`/`}` rewritten, expr kept
    <Card title={x} />          `_( Card{title=(x)  })` -- the same byte-aligned
                                lowering `.luax` gets (virtual_source)
    prose, frontmatter, other   blanked to spaces (newlines kept)
    code fences

  plus two insertions: `local function _(...) end return function(props) `
  after the setup code, and ` end` at the end of the file. `props` is the
  component's own parameter, exactly as in the compiled module.

  The result is a list of small hunks (LuaLS's OnSetText diff format): only
  bytes that actually change are inside a hunk, so rename/references on the
  code in between map back exactly (see hydronium_luax.plugin.compute_diff
  for why one large hunk breaks that). Hunks that touch are merged, because
  LuaLS orders hunks with an unstable sort on `start`.

  Deliberately a line scanner, not the Markdown compiler: it must keep
  working on half-typed documents the compiler would reject.
]]
local markdown = require("hydronium_luax.markdown")
local virtual_source = require("hydronium_luax.luals.virtual_source")

local M = {}

M.HEADER = "local function _(...) end return function(props)"
M.FOOTER = " end"

local function fence_open(line)
  local run, info = line:match("^%s*(```+)(.*)$")
  if not run then run, info = line:match("^%s*(~~~+)(.*)$") end
  if not run then return nil end
  return { char = run:sub(1, 1), length = #run, info = info:gsub("^%s+", ""):gsub("%s+$", "") }
end

--- Byte ranges that are never scanned for expressions, and setup code ranges.
local function regions(text, mdx)
  local lines, starts = {}, {}
  local position = 1
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
    starts[#starts + 1] = position
    position = position + #line + 1
  end
  if text:sub(-1) == "\n" then lines[#lines] = nil; starts[#starts] = nil end

  local skip, setup = {}, {}
  local setup_end = nil -- byte just after the last setup fence's closing line
  local i = 1
  if lines[1] == "---" then
    for j = 2, #lines do
      if lines[j] == "---" or lines[j] == "..." then
        skip[#skip + 1] = { starts[1], starts[j] + #lines[j] - 1 }
        i = j + 1
        break
      end
    end
  end
  while i <= #lines do
    local fence = fence_open(lines[i])
    if fence then
      local j = i + 1
      while j <= #lines do
        local close = lines[j]:match("^%s*([`~]+)%s*$")
        if close and close:sub(1, 1) == fence.char and #close >= fence.length
            and close == string.rep(fence.char, #close) then
          break
        end
        j = j + 1
      end
      local last = math.min(j, #lines)
      local line_end = starts[last] + #lines[last] - 1
      if mdx and fence.info:match("^lua%s+setup$") then
        skip[#skip + 1] = { starts[i], starts[i] + #lines[i] - 1 }
        if j > i + 1 then
          setup[#setup + 1] = { starts[i + 1], starts[j - 1] + #lines[j - 1] - 1 }
        end
        if j <= #lines then skip[#skip + 1] = { starts[j], line_end } end
        setup_end = line_end + 2
      else
        skip[#skip + 1] = { starts[i], line_end }
      end
      i = last + 1
    else
      i = i + 1
    end
  end
  return skip, setup, setup_end
end

--- Projects `text` into { text = virtual_lua, [n] = { start, finish, text } }.
--- @param text string the document
--- @param filename string used to pick md (no code) vs mdx
function M.project(text, filename)
  local mdx = (filename or ""):match("%.mdx$") ~= nil
  local skip, setup, setup_end = regions(text, mdx)

  -- Per byte: what the virtual document holds there. nil = blank it.
  local keep = {}
  local replace = {} -- [byte] = replacement text for exactly that byte
  local inserts = {} -- [byte] = text inserted before that byte
  local skipped = {}
  for _, range in ipairs(skip) do for b = range[1], range[2] do skipped[b] = true end end
  for _, range in ipairs(setup) do for b = range[1], range[2] do keep[b] = true end end

  local header_at = setup_end or 1
  if header_at > #text + 1 then header_at = #text + 1 end
  inserts[header_at] = M.HEADER

  if mdx then
    local i = setup_end or 1
    while i <= #text do
      local c = text:sub(i, i)
      if skipped[i] or keep[i] then
        i = i + 1
      elseif c == "\\" then
        i = i + 2
      elseif c == "`" then
        local run = text:match("^`+", i)
        local close = text:find(run, i + #run, true)
        local blank_line = text:find("\n%s*\n", i)
        if close and (not blank_line or close < blank_line) then i = close + #run else i = i + #run end
      elseif c == "{" then
        local stop = markdown.matching_brace(text, i)
        if not stop then break end -- half-typed expression: leave the rest blank
        replace[i] = "_("
        for b = i + 1, stop - 2 do keep[b] = true end
        replace[stop - 1] = ")"
        i = stop
      elseif c == "<" and (text:match("^<[A-Z]", i) or text:match("^<[%a_][%w_]*%.[%a_]", i)) then
        local j, found = i, nil
        for _ = 1, 400 do
          local close = text:find(">", j + 1, true)
          if not close then break end
          if markdown.parses(text:sub(i, close)) then found = close; break end
          j = close
        end
        if found then
          local source = text:sub(i, found)
          local lowered = virtual_source.transform("_(" .. source .. ")", filename):sub(3, -2)
          if #lowered == #source then
            for k = 1, #source do
              local b = i + k - 1
              if lowered:sub(k, k) == source:sub(k, k) then keep[b] = true
              else replace[b] = lowered:sub(k, k) end
            end
            inserts[i] = (inserts[i] or "") .. "_("
            inserts[found + 1] = ")" .. (inserts[found + 1] or "")
          end
          i = found + 1
        else
          i = i + 1 -- half-typed element: blank it, keep scanning
        end
      else
        i = i + 1
      end
    end
  end
  inserts[#text + 1] = (inserts[#text + 1] or "") .. M.FOOTER

  -- Blanked bytes that run to the end of their line are dropped rather than
  -- padded (a padded line would be all trailing whitespace to LuaLS). Code
  -- never moves: only bytes after a line's last code byte are removed.
  local function blanked(b)
    local c = text:sub(b, b)
    return not keep[b] and not replace[b] and c ~= "\n"
  end
  local trailing = {}
  for b = #text, 1, -1 do
    local nxt = text:sub(b + 1, b + 1)
    local ends_line = nxt == "\n" or b == #text
    trailing[b] = blanked(b) and not inserts[b + 1] and (ends_line or trailing[b + 1] == true)
  end

  -- Build hunks in byte order; unchanged bytes stay outside every hunk.
  local hunks, out = {}, {}
  local function add(start, finish, replacement)
    local last = hunks[#hunks]
    if last and start <= last.finish + 1 then
      last.text = last.text .. replacement
      if finish > last.finish then last.finish = finish end
    else
      hunks[#hunks + 1] = { start = start, finish = finish, text = replacement }
    end
  end
  for b = 1, #text + 1 do
    if inserts[b] then
      add(b, b - 1, inserts[b]); out[#out + 1] = inserts[b]
    end
    if b <= #text then
      local c = text:sub(b, b)
      local v
      if replace[b] then v = replace[b]
      elseif trailing[b] then v = ""
      elseif keep[b] or c == "\n" or c == " " then v = c
      else v = c == "\r" and "\r" or " " end
      out[#out + 1] = v
      if v ~= c then add(b, b, v) end
    end
  end
  hunks.text = table.concat(out)
  return hunks
end

return M
