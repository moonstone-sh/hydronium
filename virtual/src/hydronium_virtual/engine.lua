-- Deterministic, host- and framework-free virtual geometry.
local Engine = {}
Engine.__index = Engine

local function lowbit(index)
  local bit = 1
  while index % (bit * 2) == 0 do bit = bit * 2 end
  return bit
end
local function add(tree, index, delta)
  while index <= #tree do tree[index] = tree[index] + delta; index = index + lowbit(index) end
end
local function sum(tree, index)
  local total = 0
  while index > 0 do total = total + tree[index]; index = index - lowbit(index) end
  return total
end

function Engine.new(count, estimate, key, sizes)
  local self = setmetatable({ count = count, estimate = estimate, key = key, sizes = sizes or {}, tree = {} }, Engine)
  for i = 1, count do self.tree[i] = 0 end
  for index = 0, count - 1 do add(self.tree, index + 1, self.sizes[key(index)] or estimate(index)) end
  return self
end
function Engine:size(index) return sum(self.tree, index + 1) - sum(self.tree, index) end
function Engine:offset(index) return sum(self.tree, index) end
function Engine:total() return sum(self.tree, #self.tree) end
function Engine:measure(index, size)
  local key, previous = self.key(index), self:size(index)
  self.sizes[key] = size; add(self.tree, index + 1, size - previous)
end
function Engine:index_at(offset)
  if self.count == 0 then return 0 end
  local target, index, bit = math.max(0, offset), 0, 1
  while bit * 2 <= self.count do bit = bit * 2 end
  while bit > 0 do
    local next_index = index + bit
    if next_index <= self.count and self.tree[next_index] <= target then target, index = target - self.tree[next_index], next_index end
    bit = math.floor(bit / 2)
  end
  return math.min(index, self.count - 1)
end

return Engine
