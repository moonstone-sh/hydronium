--[[
  Hydronium ComponentFamily Registry (HMR generalization)

  A ComponentFamily is stable identity for "the current definition of
  this component, wherever it's mounted" -- surviving normal source
  edits, independent of any single ComponentInstance's raw function/
  table reference (which core/component.lua's `self.type` has always
  been, with no notion of "this is a newer version of the same thing").

  Deliberately NOT keyed by memory address, runtime table identity,
  generated chunk filename, line/column, or a random value -- all
  explicitly rejected as primary identity by design (see
  docs/HMR_COMPONENT_FAMILIES.md). Family IDs are assigned by
  `hydronium.core.family_loader`, which derives them from a real
  `require()` module id plus the export name -- this module only owns
  the registry and the refresh fan-out, not identity derivation.

  Instance membership is tracked with an explicit register/unregister
  pair (called from core/component.lua's mount/unmount), not a weak
  table alone: HMR needs a deterministic, immediately-accurate answer to
  "which instances are live right now," not one that depends on when
  the garbage collector next runs.
--]]

local familyModule = {}

local Family = {}
Family.__index = Family

--- @param id string e.g. "app.components.counter::Counter"
function Family.new(id)
  return setmetatable({
    id = id,
    current_definition = nil,
    generation = 0,
    instances = {}, -- ComponentInstance -> true
    instance_count = 0,
  }, Family)
end

function Family:register_instance(instance)
  if not self.instances[instance] then
    self.instances[instance] = true
    self.instance_count = self.instance_count + 1
  end
end

function Family:unregister_instance(instance)
  if self.instances[instance] then
    self.instances[instance] = nil
    self.instance_count = self.instance_count - 1
  end
end

--- Updates this family's definition and refreshes every currently
--- mounted, live instance through the instance's own ComponentInstance:refresh()
--- (real setup rerun + normal reconciliation -- see core/component.lua;
--- this module never touches the DOM or the render tree directly).
--- @param new_definition function|table
--- @return { generation: integer, refreshed: integer, failed: integer, family_id: string }
function Family:update_definition(new_definition)
  self.generation = self.generation + 1
  self.current_definition = new_definition

  local refreshed, failed = 0, 0
  -- Snapshot first: an instance's own refresh may mount/unmount other
  -- instances (of this or another family) as a side effect of
  -- reconciliation, which would otherwise mutate `self.instances` while
  -- this loop iterates it.
  local live = {}
  for instance in pairs(self.instances) do
    table.insert(live, instance)
  end

  for _, instance in ipairs(live) do
    if self.instances[instance] then -- still mounted as of this pass
      local ok = instance:refresh(new_definition)
      if ok then
        refreshed = refreshed + 1
      else
        failed = failed + 1
      end
    end
  end

  return {
    family_id = self.id,
    generation = self.generation,
    refreshed = refreshed,
    failed = failed,
  }
end

local families = {}

--- @param family_id string
--- @return Family
function familyModule.get_or_create(family_id)
  local fam = families[family_id]
  if not fam then
    fam = Family.new(family_id)
    families[family_id] = fam
  end
  return fam
end

--- @param family_id string
--- @return Family?
function familyModule.get(family_id)
  return families[family_id]
end

--- @return { [string]: Family }
function familyModule.all()
  return families
end

--- Test-only: clears the entire registry. Never call this in real
--- application/dev code.
function familyModule.reset()
  families = {}
end

familyModule.Family = Family

return familyModule
