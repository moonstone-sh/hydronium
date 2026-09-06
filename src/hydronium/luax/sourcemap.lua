-- Base64 VLQ SourceMap V3 implementation for Hydronium LUAX
local M = {}

local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_MAP = {}
for i = 1, #B64_CHARS do
  B64_MAP[B64_CHARS:sub(i, i)] = i - 1
end

-- Encode a single signed integer to Base64 VLQ
function M.encode_vlq(num)
  local sign_val
  if num < 0 then
    sign_val = (-num) * 2 + 1
  else
    sign_val = num * 2
  end

  local chars = {}
  repeat
    local digit = sign_val % 32
    sign_val = math.floor(sign_val / 32)
    if sign_val > 0 then
      digit = digit + 32 -- continuation bit
    end
    table.insert(chars, B64_CHARS:sub(digit + 1, digit + 1))
  until sign_val == 0

  return table.concat(chars)
end

-- Decode Base64 VLQ string into array of numbers
function M.decode_vlq(str, pos)
  pos = pos or 1
  local result = 0
  local shift = 1
  local len = #str

  while pos <= len do
    local char = str:sub(pos, pos)
    pos = pos + 1
    local val = B64_MAP[char]
    if not val then
      error("Invalid base64 character in VLQ: " .. tostring(char))
    end

    local continuation = val >= 32
    local digit = val % 32
    result = result + digit * shift
    shift = shift * 32

    if not continuation then
      local is_neg = (result % 2) == 1
      local num = math.floor(result / 2)
      if is_neg then
        num = -num
      end
      return num, pos
    end
  end

  error("Unterminated VLQ sequence at pos " .. pos)
end

-- SourceMap Generator
local SourceMap = {}
SourceMap.__index = SourceMap

function M.create(options)
  options = options or {}
  local sm = {
    version = 3,
    file = options.file or "output.lua",
    sourceRoot = options.sourceRoot or "",
    sources = options.sources or {},
    sourcesContent = options.sourcesContent or {},
    names = options.names or {},
    mappings = {}, -- table of line -> list of segments
  }
  return setmetatable(sm, SourceMap)
end

function SourceMap:add_source(source_path, content)
  for i, s in ipairs(self.sources) do
    if s == source_path then
      return i - 1
    end
  end
  table.insert(self.sources, source_path)
  table.insert(self.sourcesContent, content or false)
  return #self.sources - 1
end

-- Add a coordinate mapping
-- Lines are 1-based, columns are 1-based (standard Lua / editor conventions)
-- Internally converted to 0-based as required by SourceMap V3 spec
function SourceMap:add_mapping(gen_line, gen_col, orig_line, orig_col, source_index, name_index)
  gen_line = gen_line or 1
  gen_col = (gen_col or 1) - 1
  if gen_col < 0 then gen_col = 0 end

  local segment = {
    gen_col = gen_col,
  }

  if orig_line and orig_col then
    segment.orig_line = orig_line - 1
    segment.orig_col = orig_col - 1
    segment.source_index = source_index or 0
    if name_index then
      segment.name_index = name_index
    end
  end

  if not self.mappings[gen_line] then
    self.mappings[gen_line] = {}
  end
  table.insert(self.mappings[gen_line], segment)
end

-- Encode all mappings to the V3 mappings string
function SourceMap:encode_mappings()
  local max_line = 0
  for line in pairs(self.mappings) do
    if line > max_line then max_line = line end
  end

  local encoded_lines = {}
  local prev_source = 0
  local prev_orig_line = 0
  local prev_orig_col = 0
  local prev_name = 0

  for line = 1, max_line do
    local line_segments = self.mappings[line]
    if not line_segments or #line_segments == 0 then
      table.insert(encoded_lines, "")
    else
      -- Sort segments by generated column
      table.sort(line_segments, function(a, b)
        return a.gen_col < b.gen_col
      end)

      local encoded_segments = {}
      local prev_gen_col = 0

      for _, seg in ipairs(line_segments) do
        local parts = {}
        -- 1. Generated column (relative to previous in same line)
        local gen_col_delta = seg.gen_col - prev_gen_col
        prev_gen_col = seg.gen_col
        table.insert(parts, M.encode_vlq(gen_col_delta))

        if seg.orig_line ~= nil then
          -- 2. Source file index
          local source_delta = seg.source_index - prev_source
          prev_source = seg.source_index
          table.insert(parts, M.encode_vlq(source_delta))

          -- 3. Original source line
          local orig_line_delta = seg.orig_line - prev_orig_line
          prev_orig_line = seg.orig_line
          table.insert(parts, M.encode_vlq(orig_line_delta))

          -- 4. Original source column
          local orig_col_delta = seg.orig_col - prev_orig_col
          prev_orig_col = seg.orig_col
          table.insert(parts, M.encode_vlq(orig_col_delta))

          -- 5. Optional name index
          if seg.name_index ~= nil then
            local name_delta = seg.name_index - prev_name
            prev_name = seg.name_index
            table.insert(parts, M.encode_vlq(name_delta))
          end
        end

        table.insert(encoded_segments, table.concat(parts))
      end

      table.insert(encoded_lines, table.concat(encoded_segments, ","))
    end
  end

  return table.concat(encoded_lines, ";")
end

-- Convert to V3 table format
function SourceMap:to_table()
  return {
    version = self.version,
    file = self.file,
    sourceRoot = self.sourceRoot,
    sources = self.sources,
    sourcesContent = self.sourcesContent,
    names = self.names,
    mappings = self:encode_mappings(),
  }
end

-- Helper to JSON serialize table
local function escape_json_str(s)
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  return '"' .. s .. '"'
end

function M.to_json(t)
  local parts = {
    '"version": ' .. tostring(t.version),
    '"file": ' .. escape_json_str(t.file or ""),
    '"sourceRoot": ' .. escape_json_str(t.sourceRoot or ""),
  }

  local src_parts = {}
  for _, s in ipairs(t.sources or {}) do
    table.insert(src_parts, escape_json_str(s))
  end
  table.insert(parts, '"sources": [' .. table.concat(src_parts, ", ") .. ']')

  local content_parts = {}
  for _, c in ipairs(t.sourcesContent or {}) do
    if type(c) == "string" then
      table.insert(content_parts, escape_json_str(c))
    else
      table.insert(content_parts, "null")
    end
  end
  table.insert(parts, '"sourcesContent": [' .. table.concat(content_parts, ", ") .. ']')

  local name_parts = {}
  for _, n in ipairs(t.names or {}) do
    table.insert(name_parts, escape_json_str(n))
  end
  table.insert(parts, '"names": [' .. table.concat(name_parts, ", ") .. ']')
  table.insert(parts, '"mappings": ' .. escape_json_str(t.mappings or ""))

  return "{\n  " .. table.concat(parts, ",\n  ") .. "\n}"
end

function SourceMap:to_json()
  return M.to_json(self:to_table())
end

function SourceMap:to_comment()
  local json = self:to_json()
  return "--# sourceMappingURL=data:application/json;charset=utf-8," .. json:gsub("\n", "")
end

-- Decode a mappings string into parsed coordinates
function M.decode_mappings(mappings_str)
  local decoded = {}
  local lines = {}
  local cur = 1
  while cur <= #mappings_str do
    local semi = mappings_str:find(";", cur, true)
    if semi then
      table.insert(lines, mappings_str:sub(cur, semi - 1))
      cur = semi + 1
    else
      table.insert(lines, mappings_str:sub(cur))
      break
    end
  end

  local prev_source = 0
  local prev_orig_line = 0
  local prev_orig_col = 0
  local prev_name = 0

  for line_idx, line_str in ipairs(lines) do
    decoded[line_idx] = {}
    if #line_str > 0 then
      local prev_gen_col = 0
      local seg_start = 1
      while seg_start <= #line_str do
        local comma = line_str:find(",", seg_start, true)
        local seg_str = comma and line_str:sub(seg_start, comma - 1) or line_str:sub(seg_start)
        seg_start = comma and (comma + 1) or (#line_str + 1)

        if #seg_str > 0 then
          local pos = 1
          local gen_col_delta, p = M.decode_vlq(seg_str, pos)
          pos = p
          local gen_col = prev_gen_col + gen_col_delta
          prev_gen_col = gen_col

          local seg = {
            gen_line = line_idx,
            gen_col = gen_col + 1, -- 1-based for users
          }

          if pos <= #seg_str then
            local source_delta, p2 = M.decode_vlq(seg_str, pos)
            pos = p2
            local source_idx = prev_source + source_delta
            prev_source = source_idx

            local orig_line_delta, p3 = M.decode_vlq(seg_str, pos)
            pos = p3
            local orig_line = prev_orig_line + orig_line_delta
            prev_orig_line = orig_line

            local orig_col_delta, p4 = M.decode_vlq(seg_str, pos)
            pos = p4
            local orig_col = prev_orig_col + orig_col_delta
            prev_orig_col = orig_col

            seg.source_index = source_idx
            seg.orig_line = orig_line + 1 -- 1-based
            seg.orig_col = orig_col + 1   -- 1-based

            if pos <= #seg_str then
              local name_delta, p5 = M.decode_vlq(seg_str, pos)
              pos = p5
              local name_idx = prev_name + name_delta
              prev_name = name_idx
              seg.name_index = name_idx
            end
          end

          table.insert(decoded[line_idx], seg)
        end
      end
    end
  end

  return decoded
end

-- Lookup original coordinates from generated coordinates
function M.lookup(decoded, gen_line, gen_col)
  local line_segs = decoded[gen_line]
  if not line_segs or #line_segs == 0 then
    return nil
  end

  -- Find closest segment <= gen_col
  local match = nil
  for _, seg in ipairs(line_segs) do
    if seg.gen_col <= gen_col then
      match = seg
    else
      break
    end
  end

  return match or line_segs[1]
end

return M
