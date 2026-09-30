--[[
  hydronium_luax.markdown -- Markdown documents as Hydronium component modules.

  `.md` is plain CommonMark (plus GFM tables and ~~strikethrough~~): nothing
  Hydronium-specific, so a document reads the same on GitHub as in an app.
  `.mdx` is to Markdown what `.luax` is to Lua: `lua setup` fences before the
  content (the module's requires), `{expr}` in prose, and LUAX component
  elements, inline or as blocks spanning several lines. `props` is in scope.

  PIPELINE: source -> block tree -> inline trees -> LUAX -> the LUAX compiler.
  The generated LUAX keeps every block on the line it came from, so the
  compiler's own source map (and its parse errors) point at the Markdown
  source, not at an intermediate file.

  RESULT: the LUAX compiler's result plus
    meta           frontmatter (`---` YAML subset: scalars and lists), or {}
    toc            { { level, id, text, line } } for every heading
    generated_luax the intermediate LUAX, for debugging

  The module itself returns a plain component function -- the shape HMR
  families, the router's lazy loader and Lab discovery all recognize.
  `props.components` replaces any element (`{ p = MyParagraph }`).

  Raw HTML is never passed through (it renders as text), and link/image URLs
  with a scheme other than http, https, mailto or tel are dropped.
]]
local luax = require("hydronium_luax.compiler")
local parser = require("hydronium_luax.parser")

local M = {}

M.TAGS = { "article", "h1", "h2", "h3", "h4", "h5", "h6", "p", "a", "img", "em", "strong", "del",
  "code", "pre", "ul", "ol", "li", "blockquote", "hr", "br", "table", "thead", "tbody", "tr", "th", "td" }

local function tag(name) return "HydroniumMd" .. name:sub(1, 1):upper() .. name:sub(2) end

--- A Lua string literal that never spans lines (keeps the LUAX line-aligned).
local function lit(value)
  return (string.format("%q", value):gsub("\\\n", "\\n"))
end

local function trim(value) return (value:gsub("^%s+", ""):gsub("%s+$", "")) end

local function fail(line, message)
  error("hydronium markdown: line " .. tostring(line) .. ": " .. message, 0)
end

-- ─── Frontmatter ───────────────────────────────────────────────────────────

local function scalar(raw)
  raw = trim(raw)
  if raw == "" then return nil end
  local quoted = raw:match('^"(.*)"$') or raw:match("^'(.*)'$")
  if quoted then return quoted end
  if raw == "true" then return true end
  if raw == "false" then return false end
  if raw == "null" or raw == "~" then return nil end
  local number = tonumber(raw)
  if number and raw:match("^[-+]?[%d.]+[eE]?[-+]?%d*$") then return number end
  local inner = raw:match("^%[(.*)%]$")
  if inner then
    local list = {}
    for item in (inner .. ","):gmatch("([^,]*),") do
      if trim(item) ~= "" then list[#list + 1] = scalar(item) end
    end
    return list
  end
  return raw
end

--- `key: value`, `key: [a, b]` and `key:` followed by `- item` lines.
local function frontmatter(lines)
  local meta, current = {}, nil
  for _, line in ipairs(lines) do
    local key, value = line:match("^([%w_%-]+)%s*:%s*(.-)%s*$")
    local item = line:match("^%s+%-%s+(.*)$") or line:match("^%-%s+(.*)$")
    if key then
      if value == "" then meta[key] = {}; current = key
      else meta[key] = scalar(value); current = nil end
    elseif item and current then
      local list = meta[current]
      list[#list + 1] = scalar(item)
    end
  end
  return meta
end

-- ─── Block structure ───────────────────────────────────────────────────────

local function blank(s) return s == nil or s:match("^%s*$") ~= nil end

local function indent_of(s) return #(s:match("^ *")) end

local function strip_indent(s, n)
  local count = 0
  while count < n and s:sub(count + 1, count + 1) == " " do count = count + 1 end
  return s:sub(count + 1)
end

local function thematic_break(s)
  if indent_of(s) > 3 then return false end
  local compact = s:gsub("[ \t]", "")
  local ch = compact:sub(1, 1)
  if #compact < 3 or not (ch == "-" or ch == "*" or ch == "_") then return false end
  return compact == string.rep(ch, #compact)
end

local function atx(s)
  local hashes, rest = s:match("^ ? ? ?(#+)(.*)$")
  if not hashes or #hashes > 6 then return nil end
  if rest ~= "" and not rest:match("^[ \t]") then return nil end
  rest = trim(rest):gsub("[ \t]+#+$", ""):gsub("^#+$", "")
  return #hashes, rest
end

local function fence_open(s)
  local indent, run, info = s:match("^( ? ? ?)(```+)(.*)$")
  if not run then indent, run, info = s:match("^( ? ? ?)(~~~+)(.*)$") end
  if not run then return nil end
  if run:sub(1, 1) == "`" and info:find("`", 1, true) then return nil end
  return { indent = #indent, char = run:sub(1, 1), length = #run, info = trim(info) }
end

local function list_marker(s)
  local indent, bullet, spaces, rest = s:match("^( ? ? ?)([-+*])( *)(.*)$")
  if bullet and (spaces ~= "" or rest == "") then
    return { ordered = false, char = bullet, indent = #indent, width = #indent + 1, spaces = #spaces, rest = rest }
  end
  local number, delimiter
  indent, number, delimiter, spaces, rest = s:match("^( ? ? ?)(%d%d?%d?%d?%d?%d?%d?%d?%d?)([.)])( *)(.*)$")
  if number and (spaces ~= "" or rest == "") then
    return { ordered = true, char = delimiter, start = tonumber(number), indent = #indent,
      width = #indent + #number + 1, spaces = #spaces, rest = rest }
  end
  return nil
end

local function table_delimiter(s)
  if not s or not s:find("-", 1, true) then return nil end
  local body = trim(s):gsub("^|", ""):gsub("|$", "")
  local align = {}
  for raw in (body .. "|"):gmatch("(.-)|") do
    local cell = trim(raw)
    if not cell:match("^:?%-+:?$") then return nil end
    local left, right = cell:sub(1, 1) == ":", cell:sub(-1) == ":"
    align[#align + 1] = (left and right) and "center" or right and "right" or left and "left" or false
  end
  return align
end

local function table_cells(s)
  local body = trim(s):gsub("^|", "")
  if body:sub(-1) == "|" and body:sub(-2, -2) ~= "\\" then body = body:sub(1, -2) end
  local cells, current, i = {}, {}, 1
  while i <= #body do
    local c = body:sub(i, i)
    if c == "\\" and body:sub(i + 1, i + 1) == "|" then current[#current + 1] = "|"; i = i + 2
    elseif c == "|" then cells[#cells + 1] = trim(table.concat(current)); current = {}; i = i + 1
    else current[#current + 1] = c; i = i + 1 end
  end
  cells[#cells + 1] = trim(table.concat(current))
  return cells
end

--- Does `s` open an MDX component element (`<Card`, `<ui.Card`, `<d.div`)?
local function component_start(s)
  return s:match("^ ? ? ?<[A-Z][%w_]*[%s/>.]") or s:match("^ ? ? ?<[%a_][%w_]*%.[%a_]")
    or s:match("^ ? ? ?<[A-Z][%w_]*$")
end

local function parses(luax_source)
  return (pcall(parser.parse, "return (" .. luax_source .. ")", "mdx-probe"))
end

local function reference_definition(s)
  local label, rest = s:match("^ ? ? ?%[([^%]]+)%]:%s*(.-)%s*$")
  if not label or rest == "" then return nil end
  local href, title = rest:match("^<([^>]*)>%s*(.*)$")
  if not href then href, title = rest:match("^(%S+)%s*(.*)$") end
  title = title and (title:match('^"(.*)"$') or title:match("^'(.*)'$") or title:match("^%((.*)%)$")) or nil
  return label, href, title
end

local function normalize_label(label)
  return trim(label):gsub("%s+", " "):lower()
end

--- Does line `s` start a block that ends a paragraph?
local function interrupts_paragraph(s, ctx)
  if blank(s) then return true end
  if indent_of(s) > 3 then return false end
  if atx(s) or fence_open(s) or thematic_break(s) or s:match("^ ? ? ?>") then return true end
  local marker = list_marker(s)
  if marker and marker.rest ~= "" and (not marker.ordered or marker.start == 1) then return true end
  if ctx.mdx and component_start(s) then return true end
  return false
end

local parse_blocks

--- Lines of a container (blockquote / list item) parsed as blocks.
local function nested(entries, ctx)
  return parse_blocks(entries, { mdx = ctx.mdx, refs = ctx.refs, nested = true })
end

--- @param entries { s: string, n: integer }[] lines with their source line numbers
parse_blocks = function(entries, ctx)
  local blocks, i = {}, 1
  local function push(block)
    if block.type ~= "setup" and block.type ~= "definition" then ctx.content_started = true end
    blocks[#blocks + 1] = block
  end

  while i <= #entries do
    local s, n = entries[i].s, entries[i].n
    local fence = fence_open(s)
    local level, title = atx(s)
    local marker = list_marker(s)

    if blank(s) then
      i = i + 1

    elseif fence then
      local content, closed = {}, false
      local j = i + 1
      while j <= #entries do
        local line = entries[j].s
        local close = line:match("^ ? ? ?(" .. fence.char:gsub("~", "%%~") .. "+)%s*$")
        if close and #close >= fence.length then closed = true; break end
        content[#content + 1] = strip_indent(line, fence.indent)
        j = j + 1
      end
      local code = table.concat(content, "\n")
      local language, directive = fence.info:match("^(%S*)%s*(.-)$")
      if ctx.mdx and language == "lua" and directive == "setup" then
        if ctx.nested then fail(n, "a `lua setup` fence must be at the top level of the document") end
        if ctx.content_started then fail(n, "a `lua setup` fence must come before the document's content") end
        push({ type = "setup", code = code, line = n + 1, fence_line = n,
          last = closed and entries[j].n or entries[#entries].n })
      else
        push({ type = "code", language = language ~= "" and language or nil, text = code, line = n,
          last = closed and entries[j].n or entries[#entries].n })
      end
      i = closed and j + 1 or j

    elseif level then
      push({ type = "heading", level = level, raw = title, line = n })
      i = i + 1

    elseif thematic_break(s) then
      push({ type = "hr", line = n })
      i = i + 1

    elseif s:match("^ ? ? ?>") then
      local inner, j = {}, i
      while j <= #entries do
        local line = entries[j].s
        local quoted = line:match("^ ? ? ?> ?(.*)$")
        if quoted then inner[#inner + 1] = { s = quoted, n = entries[j].n }
        elseif not blank(line) and #inner > 0 and not blank(inner[#inner].s)
            and not interrupts_paragraph(line, ctx) then
          inner[#inner + 1] = { s = line, n = entries[j].n } -- lazy continuation
        else break end
        j = j + 1
      end
      push({ type = "blockquote", children = nested(inner, ctx), line = n })
      i = j

    elseif marker and indent_of(s) <= 3 then
      local list = { type = "list", ordered = marker.ordered, start = marker.start, char = marker.char,
        tight = true, items = {}, line = n }
      local j = i
      while j <= #entries do
        local m = list_marker(entries[j].s)
        if not m or m.ordered ~= list.ordered or m.char ~= list.char then break end
        local spaces = m.spaces
        if spaces > 4 or m.rest == "" then spaces = 1 end
        local width = m.width + spaces
        local first = m.rest
        if m.spaces > 4 then first = string.rep(" ", m.spaces - 1) .. m.rest end
        local inner = { { s = first, n = entries[j].n } }
        local k = j + 1
        local saw_blank = false
        while k <= #entries do
          local line = entries[k].s
          if blank(line) then
            inner[#inner + 1] = { s = "", n = entries[k].n }; saw_blank = true
          elseif indent_of(line) >= width then
            inner[#inner + 1] = { s = strip_indent(line, width), n = entries[k].n }; saw_blank = false
          elseif not saw_blank and not blank(inner[#inner].s) and not list_marker(line)
              and not interrupts_paragraph(line, ctx) then
            -- Lazy continuation; a list marker here starts the next item instead.
            inner[#inner + 1] = { s = line, n = entries[k].n }
          else break end
          k = k + 1
        end
        -- Trailing blank lines belong between items, not inside this one.
        local trailing = 0
        while #inner > 1 and blank(inner[#inner].s) do inner[#inner] = nil; trailing = trailing + 1 end
        for index = 2, #inner - 1 do
          if blank(inner[index].s) then list.tight = false end
        end
        list.items[#list.items + 1] = { children = nested(inner, ctx), line = entries[j].n }
        j = k
        if trailing > 0 and j <= #entries then
          local next_marker = list_marker(entries[j].s)
          if next_marker and next_marker.ordered == list.ordered and next_marker.char == list.char then
            list.tight = false
          end
        end
      end
      push(list)
      i = j

    elseif ctx.mdx and component_start(s) then
      local parts, j = {}, i
      local found = false
      while j <= #entries do
        parts[#parts + 1] = entries[j].s
        if parses(table.concat(parts, "\n")) then found = true; break end
        j = j + 1
      end
      if not found then fail(n, "component element is never closed (or is not valid LUAX)") end
      push({ type = "component", source = table.concat(parts, "\n"), line = n })
      i = j + 1

    elseif indent_of(s) >= 4 then
      local content, j = {}, i
      while j <= #entries and (blank(entries[j].s) or indent_of(entries[j].s) >= 4) do
        content[#content + 1] = strip_indent(entries[j].s, 4)
        j = j + 1
      end
      while #content > 0 and blank(content[#content]) do content[#content] = nil end
      push({ type = "code", text = table.concat(content, "\n"), line = n, last = entries[j - 1].n })
      i = j

    else
      local label, href, link_title = reference_definition(s)
      local align = s:find("|", 1, true) and entries[i + 1] and table_delimiter(entries[i + 1].s)
      local header = align and table_cells(s)
      if label then
        local key = normalize_label(label)
        if not ctx.refs[key] then ctx.refs[key] = { href = href, title = link_title } end
        push({ type = "definition", line = n })
        i = i + 1
      elseif header and #header == #align then
        local rows, j = {}, i + 2
        while j <= #entries and not blank(entries[j].s) and entries[j].s:find("|", 1, true)
            and not interrupts_paragraph(entries[j].s, ctx) do
          rows[#rows + 1] = table_cells(entries[j].s)
          j = j + 1
        end
        push({ type = "table", align = align, header = header, rows = rows, line = n })
        i = j
      else
        local text, j = { (s:gsub("^%s+", "")) }, i + 1
        local heading_level
        while j <= #entries do
          local line = entries[j].s
          if line:match("^ ? ? ?=+%s*$") then heading_level = 1; j = j + 1; break end
          if line:match("^ ? ? ?%-+%s*$") then heading_level = 2; j = j + 1; break end
          if interrupts_paragraph(line, ctx) then break end
          text[#text + 1] = line:gsub("^%s+", "")
          j = j + 1
        end
        local raw = table.concat(text, "\n")
        if heading_level then
          push({ type = "heading", level = heading_level, raw = trim(raw), line = n })
        else
          push({ type = "paragraph", raw = raw:gsub("%s+$", ""), line = n })
        end
        i = j
      end
    end
  end
  return blocks
end

-- ─── Inline content ────────────────────────────────────────────────────────

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160",
  copy = "\194\169", reg = "\194\174", hellip = "\226\128\166", mdash = "\226\128\148",
  ndash = "\226\128\147", lsquo = "\226\128\152", rsquo = "\226\128\153", ldquo = "\226\128\156",
  rdquo = "\226\128\157", times = "\195\151", middot = "\194\183", rarr = "\226\134\146", larr = "\226\134\144" }

local function utf8_char(code)
  if code < 0x80 then return string.char(code) end
  if code < 0x800 then return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40) end
  if code < 0x10000 then
    return string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
    0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local function entity(s, i)
  local name, stop = s:match("^&([%a][%w]*);()", i)
  if name and ENTITIES[name] then return ENTITIES[name], stop end
  local hex, hex_stop = s:match("^&#[xX](%x+);()", i)
  if hex then return utf8_char(tonumber(hex, 16)), hex_stop end
  local dec, dec_stop = s:match("^&#(%d+);()", i)
  if dec then return utf8_char(tonumber(dec)), dec_stop end
  return nil
end

local PUNCT = "[!\"#$%%&'()*+,%-./:;<=>?@%[\\%]^_`{|}~]"

local function is_space(c) return c == "" or c:match("%s") ~= nil end
local function is_punct(c) return c ~= "" and c:match(PUNCT) ~= nil end

--- Index just past the `}` matching the `{` at `i`, skipping Lua strings.
local function matching_brace(s, i)
  local depth, j = 0, i
  while j <= #s do
    local c = s:sub(j, j)
    if c == '"' or c == "'" then
      local k = j + 1
      while k <= #s and s:sub(k, k) ~= c do
        if s:sub(k, k) == "\\" then k = k + 1 end
        k = k + 1
      end
      j = k
    elseif c == "{" then depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth == 0 then return j + 1 end
    end
    j = j + 1
  end
  return nil
end

--- `(dest "title")` right after a `]`; returns href, title, index after `)`.
local function inline_destination(s, i)
  if s:sub(i, i) ~= "(" then return nil end
  local j = i + 1
  while s:sub(j, j):match("^%s$") do j = j + 1 end
  local href
  if s:sub(j, j) == "<" then
    local close = s:find(">", j + 1, true)
    if not close then return nil end
    href = s:sub(j + 1, close - 1); j = close + 1
  else
    local depth, start = 0, j
    while j <= #s do
      local c = s:sub(j, j)
      if c == "\\" then j = j + 1
      elseif c == "(" then depth = depth + 1
      elseif c == ")" then
        if depth == 0 then break end
        depth = depth - 1
      elseif c:match("%s") then break end
      j = j + 1
    end
    href = s:sub(start, j - 1)
  end
  while s:sub(j, j):match("^%s$") do j = j + 1 end
  local title
  local opener = s:sub(j, j)
  local closer = opener == '"' and '"' or opener == "'" and "'" or opener == "(" and ")" or nil
  if closer then
    local close = s:find(closer, j + 1, true)
    if not close then return nil end
    title = s:sub(j + 1, close - 1); j = close + 1
    while s:sub(j, j):match("^%s$") do j = j + 1 end
  end
  if s:sub(j, j) ~= ")" then return nil end
  return href:gsub("\\(" .. PUNCT .. ")", "%1"), title, j + 1
end

--- CommonMark's "process emphasis" over the delimiter list, in place.
local function process_emphasis(nodes)
  local i = 1
  while i <= #nodes do
    local closer = nodes[i]
    if closer.type == "delim" and closer.can_close and closer.count > 0 then
      local found
      for j = i - 1, 1, -1 do
        local opener = nodes[j]
        if opener.type == "delim" and opener.char == closer.char and opener.can_open and opener.count > 0 then
          local odd = (opener.can_close or closer.can_open)
            and (opener.origin + closer.origin) % 3 == 0
            and not (opener.origin % 3 == 0 and closer.origin % 3 == 0)
          local strike_ok = opener.char ~= "~" or (opener.count == 2 and closer.count == 2)
          if not odd and strike_ok then found = j; break end
        end
      end
      if found then
        local opener = nodes[found]
        local use = opener.char == "~" and 2 or ((opener.count >= 2 and closer.count >= 2) and 2 or 1)
        local kind = opener.char == "~" and "del" or (use == 2 and "strong" or "em")
        local children = {}
        for k = found + 1, i - 1 do
          local child = nodes[k]
          -- Delimiters left between a matched pair can no longer match.
          if child.type == "delim" then child = { type = "text", value = string.rep(child.char, child.count) } end
          children[#children + 1] = child
        end
        for k = i - 1, found + 1, -1 do table.remove(nodes, k) end
        table.insert(nodes, found + 1, { type = kind, children = children })
        opener.count, closer.count = opener.count - use, closer.count - use
        i = found + 2
      else
        if not closer.can_open then closer.can_close = false end
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  -- Unmatched delimiters are just text.
  for index, node in ipairs(nodes) do
    if node.type == "delim" then nodes[index] = { type = "text", value = string.rep(node.char, node.count) } end
  end
  return nodes
end

local parse_inline

--- Parses inline Markdown into nodes: text, code, em, strong, del, link,
--- image, br, expr (mdx) and luax (inline mdx component).
parse_inline = function(s, ctx)
  local nodes, buffer = {}, {}
  local brackets = {}
  local function flush()
    if #buffer > 0 then nodes[#nodes + 1] = { type = "text", value = table.concat(buffer) }; buffer = {} end
  end
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "\\" then
      local nxt = s:sub(i + 1, i + 1)
      if nxt == "\n" then flush(); nodes[#nodes + 1] = { type = "br" }; i = i + 2
      elseif is_punct(nxt) then buffer[#buffer + 1] = nxt; i = i + 2
      else buffer[#buffer + 1] = c; i = i + 1 end

    elseif c == "`" then
      local run = s:match("^`+", i)
      local close_start, close_stop = i + #run, nil
      while true do
        local a, b = s:find("`+", close_start)
        if not a then break end
        if b - a + 1 == #run then close_stop = b; close_start = a; break end
        close_start = b + 1
      end
      if close_stop then
        local code = s:sub(i + #run, close_start - 1):gsub("\n", " ")
        if code:match("^ .* $") and not code:match("^ +$") then code = code:sub(2, -2) end
        flush(); nodes[#nodes + 1] = { type = "code", value = code }
        i = close_stop + 1
      else
        buffer[#buffer + 1] = run; i = i + #run
      end

    elseif c == "{" and ctx.mdx then
      local stop = matching_brace(s, i)
      if not stop then fail(ctx.line, "unclosed `{` expression") end
      flush(); nodes[#nodes + 1] = { type = "expr", source = s:sub(i, stop - 1) }
      i = stop

    elseif c == "<" then
      local uri, uri_stop = s:match("^<([%a][%w+.%-]*:[^%s<>]*)>()", i)
      local email, email_stop = s:match("^<([%w.!#$%%&'*+/=?^_`{|}~%-]+@[%w%-]+[%w.%-]*)>()", i)
      if uri then
        flush(); nodes[#nodes + 1] = { type = "link", href = uri, children = { { type = "text", value = uri } } }
        i = uri_stop
      elseif email then
        flush(); nodes[#nodes + 1] = { type = "link", href = "mailto:" .. email, children = { { type = "text", value = email } } }
        i = email_stop
      elseif ctx.mdx and (s:match("^<[A-Z]", i) or s:match("^<[%a_][%w_]*%.[%a_]", i)) then
        local j, found = i, nil
        while true do
          local close = s:find(">", j + 1, true)
          if not close then break end
          if parses(s:sub(i, close)) then found = close; break end
          j = close
        end
        if not found then fail(ctx.line, "inline component element is never closed (or is not valid LUAX)") end
        flush(); nodes[#nodes + 1] = { type = "luax", source = s:sub(i, found) }
        i = found + 1
      else
        buffer[#buffer + 1] = c; i = i + 1
      end

    elseif c == "&" then
      local decoded, stop = entity(s, i)
      if decoded then buffer[#buffer + 1] = decoded; i = stop
      else buffer[#buffer + 1] = c; i = i + 1 end

    elseif c == "!" and s:sub(i + 1, i + 1) == "[" then
      flush(); nodes[#nodes + 1] = { type = "text", value = "![" }
      brackets[#brackets + 1] = { index = #nodes, image = true, active = true, start = i + 2 }
      i = i + 2

    elseif c == "[" then
      flush(); nodes[#nodes + 1] = { type = "text", value = "[" }
      brackets[#brackets + 1] = { index = #nodes, image = false, active = true, start = i + 1 }
      i = i + 1

    elseif c == "]" then
      flush()
      local opener = brackets[#brackets]
      local matched = false
      if opener and opener.active then
        local href, title, stop = inline_destination(s, i + 1)
        if not href then
          local label_text = s:sub(opener.start, i - 1)
          local ref_label, ref_stop = s:match("^%[([^%]]*)%]()", i + 1)
          local key = (ref_label and ref_label ~= "") and ref_label or label_text
          local ref = ctx.refs[normalize_label(key)]
          if ref then
            href, title, stop = ref.href, ref.title, ref_label and ref_stop or i + 1
          end
        end
        if href then
          local children = {}
          for k = opener.index + 1, #nodes do children[#children + 1] = nodes[k] end
          for k = #nodes, opener.index, -1 do nodes[k] = nil end
          process_emphasis(children)
          if opener.image then
            nodes[#nodes + 1] = { type = "image", src = href, title = title, children = children }
          else
            nodes[#nodes + 1] = { type = "link", href = href, title = title, children = children }
            for _, earlier in ipairs(brackets) do
              if not earlier.image then earlier.active = false end
            end
          end
          brackets[#brackets] = nil
          i = stop
          matched = true
        end
      end
      if not matched then
        if opener then brackets[#brackets] = nil end
        nodes[#nodes + 1] = { type = "text", value = "]" }
        i = i + 1
      end

    elseif c == "*" or c == "_" or c == "~" then
      local run = s:match("^%" .. c .. "+", i)
      if c == "~" and #run ~= 2 then
        buffer[#buffer + 1] = run; i = i + #run
      else
        flush()
        local before, after = s:sub(i - 1, i - 1), s:sub(i + #run, i + #run)
        local left = not is_space(after) and (not is_punct(after) or is_space(before) or is_punct(before))
        local right = not is_space(before) and (not is_punct(before) or is_space(after) or is_punct(after))
        local can_open, can_close = left, right
        if c == "_" then
          can_open = left and (not right or is_punct(before))
          can_close = right and (not left or is_punct(after))
        end
        nodes[#nodes + 1] = { type = "delim", char = c, count = #run, origin = #run, can_open = can_open, can_close = can_close }
        i = i + #run
      end

    elseif c == "\n" then
      -- Two or more trailing spaces make a hard break; otherwise a soft one.
      local trailing = 0
      while buffer[#buffer] == " " do buffer[#buffer] = nil; trailing = trailing + 1 end
      if trailing >= 2 then flush(); nodes[#nodes + 1] = { type = "br" }
      else buffer[#buffer + 1] = " " end
      i = i + 1
      while s:sub(i, i) == " " do i = i + 1 end

    else
      buffer[#buffer + 1] = c; i = i + 1
    end
  end
  flush()
  process_emphasis(nodes)
  -- Merge adjacent text so a paragraph renders as few DOM text nodes as possible.
  local merged = {}
  for _, node in ipairs(nodes) do
    local last = merged[#merged]
    if node.type == "text" and last and last.type == "text" then last.value = last.value .. node.value
    elseif node.type ~= "text" or node.value ~= "" then merged[#merged + 1] = node end
  end
  return merged
end

local function plain_text(nodes)
  local out = {}
  for _, node in ipairs(nodes) do
    if node.type == "text" or node.type == "code" then out[#out + 1] = node.value
    elseif node.children then out[#out + 1] = plain_text(node.children)
    elseif node.type == "br" then out[#out + 1] = " " end
  end
  return table.concat(out)
end

local function slug(value)
  local result = value:lower():gsub("[^%w%s%-_\128-\255]", ""):gsub("%s+", "-")
  result = result:gsub("^%-+", ""):gsub("%-+$", "")
  return result ~= "" and result or "section"
end

local SAFE_SCHEMES = { http = true, https = true, mailto = true, tel = true }

local function safe_url(value)
  local normalized = trim(value):gsub("[%c%s]", "")
  local scheme = normalized:match("^([%a][%w+.%-]*):")
  if scheme and not SAFE_SCHEMES[scheme:lower()] then return nil end
  return value
end

-- ─── LUAX emission ─────────────────────────────────────────────────────────

--- Writes LUAX so every fragment starts on the line its source started on.
local Writer = {}
Writer.__index = Writer

local function writer()
  return setmetatable({ parts = {}, line = 1 }, Writer)
end

function Writer:at(line)
  if line and line > self.line then
    self.parts[#self.parts + 1] = string.rep("\n", line - self.line)
    self.line = line
  end
  return self
end

function Writer:put(text)
  self.parts[#self.parts + 1] = text
  local _, newlines = text:gsub("\n", "")
  self.line = self.line + newlines
  return self
end

function Writer:result() return table.concat(self.parts) end

local function attrs(list)
  local out = {}
  for _, pair in ipairs(list) do
    if pair[2] then out[#out + 1] = " " .. pair[1] .. "={" .. pair[2] .. "}" end
  end
  return table.concat(out)
end

local emit_inline

local function element(w, name, attributes, emit_children)
  local open = "<" .. tag(name) .. attrs(attributes or {})
  if not emit_children then w:put(open .. " />"); return end
  w:put(open .. ">")
  emit_children()
  w:put("</" .. tag(name) .. ">")
end

emit_inline = function(w, nodes)
  for _, node in ipairs(nodes) do
    local t = node.type
    if t == "text" then w:put("{" .. lit(node.value) .. "}")
    elseif t == "code" then element(w, "code", nil, function() w:put("{" .. lit(node.value) .. "}") end)
    elseif t == "em" or t == "strong" or t == "del" then
      element(w, t, nil, function() emit_inline(w, node.children) end)
    elseif t == "br" then element(w, "br")
    elseif t == "expr" then w:put((node.source:gsub("\n", " ")))
    elseif t == "luax" then w:put((node.source:gsub("\n", " ")))
    elseif t == "link" then
      if safe_url(node.href) then
        element(w, "a", { { "href", lit(node.href) }, { "title", node.title and lit(node.title) } },
          function() emit_inline(w, node.children) end)
      else
        emit_inline(w, node.children)
      end
    elseif t == "image" then
      local alt = plain_text(node.children)
      if safe_url(node.src) then
        element(w, "img", { { "src", lit(node.src) }, { "alt", lit(alt) }, { "title", node.title and lit(node.title) } })
      else
        w:put("{" .. lit(alt) .. "}")
      end
    end
  end
end

local emit_blocks

local function emit_block(w, block, ctx, tight)
  local t = block.type
  w:at(block.line)
  if t == "heading" then
    local children = parse_inline(block.raw, { mdx = ctx.mdx, refs = ctx.refs, line = block.line })
    local text = plain_text(children)
    local base = slug(text)
    ctx.ids[base] = (ctx.ids[base] or 0) + 1
    local id = ctx.ids[base] == 1 and base or (base .. "-" .. ctx.ids[base])
    ctx.toc[#ctx.toc + 1] = { level = block.level, id = id, text = text, line = block.line }
    element(w, "h" .. block.level, { { "id", lit(id) } }, function() emit_inline(w, children) end)
  elseif t == "paragraph" then
    local children = parse_inline(block.raw, { mdx = ctx.mdx, refs = ctx.refs, line = block.line })
    if #children == 1 and (children[1].type == "expr" or children[1].type == "luax") then
      emit_inline(w, children) -- a lone `{expr}` / component is a block, not prose
    elseif tight then
      emit_inline(w, children)
    else
      element(w, "p", nil, function() emit_inline(w, children) end)
    end
  elseif t == "code" then
    element(w, "pre", nil, function()
      element(w, "code", { { "class", block.language and lit("language-" .. block.language) } },
        function() w:put("{" .. lit(block.text) .. "}") end)
    end)
  elseif t == "hr" then
    element(w, "hr")
  elseif t == "blockquote" then
    element(w, "blockquote", nil, function() emit_blocks(w, block.children, ctx) end)
  elseif t == "list" then
    local name = block.ordered and "ol" or "ul"
    local start = block.ordered and block.start ~= 1 and tostring(block.start) or nil
    element(w, name, { { "start", start } }, function()
      for _, item in ipairs(block.items) do
        w:at(item.line)
        element(w, "li", nil, function() emit_blocks(w, item.children, ctx, block.tight) end)
      end
    end)
  elseif t == "table" then
    local inline_ctx = { mdx = ctx.mdx, refs = ctx.refs, line = block.line }
    local function cell(kind, text, index)
      local align = block.align[index]
      element(w, kind, { { "style", align and lit("text-align: " .. align) } }, function()
        emit_inline(w, parse_inline(text or "", inline_ctx))
      end)
    end
    element(w, "table", nil, function()
      element(w, "thead", nil, function()
        element(w, "tr", nil, function()
          for index, text in ipairs(block.header) do cell("th", text, index) end
        end)
      end)
      if #block.rows > 0 then
        element(w, "tbody", nil, function()
          for _, row in ipairs(block.rows) do
            element(w, "tr", nil, function()
              for index = 1, #block.header do cell("td", row[index], index) end
            end)
          end
        end)
      end
    end)
  elseif t == "component" then
    w:put(block.source)
  end
end

emit_blocks = function(w, blocks, ctx, tight)
  for _, block in ipairs(blocks) do
    if block.type ~= "setup" and block.type ~= "definition" then emit_block(w, block, ctx, tight) end
  end
end

-- Shared with hydronium_luax.luals.mdx, which must find the same `{expr}`
-- and component spans the compiler does.
M.matching_brace = matching_brace
M.component_start = component_start
M.parses = parses

--- Parses a document into { meta, blocks, refs } without generating code.
function M.parse(source, options)
  options = options or {}
  local filename = options.filename or "document.md"
  local mdx = filename:match("%.mdx$") ~= nil
  local lines = {}
  for line in (source:gsub("\r\n?", "\n") .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line:gsub("^\t+", function(tabs) return string.rep("    ", #tabs) end)
  end
  if #lines > 0 and lines[#lines] == "" then lines[#lines] = nil end

  local meta, first = {}, 1
  if lines[1] == "---" then
    for j = 2, #lines do
      if lines[j] == "---" or lines[j] == "..." then
        local body = {}
        for k = 2, j - 1 do body[#body + 1] = lines[k] end
        meta, first = frontmatter(body), j + 1
        break
      end
    end
  end

  local entries = {}
  for n = first, #lines do entries[#entries + 1] = { s = lines[n], n = n } end
  local ctx = { mdx = mdx, refs = {} }
  local blocks = parse_blocks(entries, ctx)
  return { meta = meta, meta_last = first - 1, blocks = blocks, refs = ctx.refs, mdx = mdx, line_count = #lines }
end

function M.compile(source, options)
  options = options or {}
  local filename = options.filename or "document.md"
  local document = M.parse(source, { filename = filename })
  local ctx = { mdx = document.mdx, refs = document.refs, ids = {}, toc = {} }

  local w = writer()
  w:put('local H = require("hydronium");')
  local first_content
  for _, block in ipairs(document.blocks) do
    if block.type == "setup" then
      w:at(block.line):put(block.code)
    elseif block.type ~= "definition" and not first_content then
      first_content = block.line
    end
  end

  local bindings = {}
  for _, name in ipairs(M.TAGS) do
    bindings[#bindings + 1] = "local " .. tag(name) .. " = components." .. name .. " or " .. lit(name) .. ";"
  end
  w:at(first_content)
  w:put(" return function(props) local components = props and props.components or {}; "
    .. table.concat(bindings, " ")
    .. " return <" .. tag("article") .. " class={props and props.class}>")
  emit_blocks(w, document.blocks, ctx)
  w:put("</" .. tag("article") .. "> end")

  local generated = w:result()
  local compiled = luax.compile(generated, { filename = filename, module_id = options.module_id,
    development = options.development, runtime = options.runtime or "hydronium",
    output_filename = (filename:gsub("%.mdx?$", ".lua")) })
  -- The generated LUAX is line-aligned with the document, so the map's
  -- positions already point into the Markdown; ship the Markdown as the
  -- source text too, so a debugger shows what the author wrote.
  if compiled.sourcemap then
    compiled.sourcemap.sourcesContent[1] = source
    compiled.map_json = compiled.sourcemap:to_json()
  end
  compiled.generated_luax = generated
  compiled.meta = document.meta
  compiled.toc = ctx.toc
  return compiled
end

return M
