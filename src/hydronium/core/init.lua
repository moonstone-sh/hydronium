--[[
  Hydronium Core Module Entry
  Exports symbols, element creation, component lifecycles, scopes, reconciler, and scheduler.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")
local errors = require("hydronium.core.errors")
local scope = require("hydronium.core.scope")
local element = require("hydronium.core.element")
local ref = require("hydronium.core.ref")
local context = require("hydronium.core.context")
local scheduler = require("hydronium.core.scheduler")
local component = require("hydronium.core.component")
local reconciler = require("hydronium.core.reconciler")

return {
  symbols = symbols,
  Fragment = symbols.FRAGMENT,

  -- Element Creation
  h = element.h,
  createElement = element.createElement,
  createTextVNode = element.createTextVNode,

  -- Scopes & Lifecycles
  Scope = scope.Scope,
  createScope = scope.createScope,
  onCleanup = scope.onCleanup,
  getScope = scope.getScope,
  runWithScope = scope.runWithScope,

  -- Component & Boundaries
  ComponentInstance = component.ComponentInstance,
  ErrorBoundary = errors.ErrorBoundary,
  HydroniumError = errors.HydroniumError,

  -- Context & Refs
  createContext = context.createContext,
  useContext = context.useContext,
  createRef = ref.createRef,

  -- Scheduler & Reconciler
  scheduler = scheduler,
  Reconciler = reconciler.Reconciler,
  setDefaultHost = reconciler.setDefaultHost,
  getDefaultReconciler = reconciler.getDefaultReconciler,
  mount = reconciler.mount,
  reconcile = reconciler.reconcile,
  unmount = reconciler.unmount,
}
