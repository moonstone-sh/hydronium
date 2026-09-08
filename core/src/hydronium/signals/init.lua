--[[
  Hydronium Signals Module Entry
  Fine-grained reactive primitives: createSignal/signal, createComputed/computed,
  createEffect/effect, batch, untrack.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local graph = require("hydronium.signals.graph")
local signal = require("hydronium.signals.signal")
local computed = require("hydronium.signals.computed")
local effect = require("hydronium.signals.effect")
local batch = require("hydronium.signals.batch")

return {
  createSignal = signal.createSignal,
  signal = signal.createSignal,
  create_signal = signal.createSignal,

  createComputed = computed.createComputed,
  computed = computed.createComputed,
  create_computed = computed.createComputed,

  createEffect = effect.createEffect,
  effect = effect.createEffect,
  create_effect = effect.createEffect,

  batch = batch.batch,
  untrack = batch.untrack,
  graph = graph,

  setSSRMode = function(val)
    local scheduler = require("hydronium.core.scheduler")
    scheduler.setSSR(val)
  end,
  isSSRMode = function()
    local scheduler = require("hydronium.core.scheduler")
    return scheduler.isSSR()
  end,
}
