local runner = require("tests.runner")
local describe, it, assert = runner.describe, runner.it, runner.assert

local family = require("hydronium.core.family")
local family_loader = require("hydronium.core.family_loader")
local hmr = require("hydronium.core.hmr")

local MODULE = "scratch.core_hmr"

local function reset()
  package.loaded[MODULE] = nil
  package.preload[MODULE] = nil
  family_loader.reset()
  family.reset()
end

describe("core HMR source replacement", function()
  it("is visible from the public Hydronium barrel", function()
    local H = require("hydronium")
    assert.equal(H.hmr, hmr)
    assert.equal(H.family_loader, family_loader)
  end)

  it("installs source as a normal require-able module", function()
    reset()
    hmr.install(MODULE, "return { value = 42 }")
    assert.equal(require(MODULE).value, 42)
    reset()
  end)

  it("does not disturb the old module when replacement cannot compile", function()
    reset()
    hmr.install(MODULE, "return { value = 1 }")
    local old = require(MODULE)
    assert.has_error(function()
      hmr.replace(MODULE, "return function(")
    end)
    assert.equal(package.loaded[MODULE], old)
    assert.equal(require(MODULE).value, 1)
    reset()
  end)

  it("restores the old loader and value when the new module errors", function()
    reset()
    hmr.install(MODULE, "return { value = 1 }")
    local old_loader = package.preload[MODULE]
    local old = require(MODULE)
    assert.has_error(function()
      hmr.replace(MODULE, "error('new module exploded')")
    end, "new module exploded")
    assert.equal(package.preload[MODULE], old_loader)
    assert.equal(package.loaded[MODULE], old)
    reset()
  end)
end)
