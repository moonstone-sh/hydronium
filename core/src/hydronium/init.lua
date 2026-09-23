--[[
  Hydronium - Fine-Grained Reactive UI Library for Lua
  Version 0.1.0
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local core = require("hydronium.core")
local signals = require("hydronium.signals")
local testModule = require("hydronium.test")

local Hydronium = {
  _VERSION = "0.1.0",
  _DESCRIPTION = "Fine-grained reactive UI library for Lua",

  -- Element Creation & Virtual DOM
  h = core.h,
  createElement = core.createElement,
  create_element = core.createElement,
  createTextVNode = core.createTextVNode,
  Fragment = core.Fragment,

  -- Reactivity Primitives
  createSignal = signals.createSignal,
  signal = signals.createSignal,
  createComputed = signals.createComputed,
  computed = signals.createComputed,
  createEffect = signals.createEffect,
  effect = signals.createEffect,
  batch = signals.batch,
  untrack = signals.untrack,

  -- Scopes & Lifecycles
  createScope = core.createScope,
  create_scope = core.createScope,
  onCleanup = core.onCleanup,
  on_cleanup = core.onCleanup,
  getScope = core.getScope,
  runWithScope = core.runWithScope,
  Scope = core.Scope,

  -- Component Systems & Resilient Boundaries
  ErrorBoundary = core.ErrorBoundary,
  HydroniumError = core.HydroniumError,
  Suspense = core.Suspense,
  resource = core.resource,
  isSuspension = core.isSuspension,

  -- Host-neutral mutations and scoped form bindings
  actions = core.actions,
  action = core.action,
  Action = core.Action,
  action_ok = core.action_ok,
  action_fail = core.action_fail,
  forms = core.forms,
  useForm = core.useForm,
  use_form = core.use_form,
  FormTransportContext = core.FormTransportContext,

  -- Context & Refs
  createContext = core.createContext,
  create_context = core.createContext,
  useContext = core.useContext,
  use_context = core.useContext,
  createRef = core.createRef,
  create_ref = core.createRef,

  -- Internal Modules & Engines
  core = core,
  signals = signals,
  symbols = core.symbols,
  scheduler = core.scheduler,
  Reconciler = core.Reconciler,
  reconciler = core.reconciler,
  setDefaultHost = core.setDefaultHost,
  getDefaultReconciler = core.getDefaultReconciler,
  mount = core.mount,
  reconcile = core.reconcile,
  unmount = core.unmount,
  hmr = core.hmr,
  family_loader = core.family_loader,
  module_graph = core.module_graph,
  hmr_host = core.hmr_host,
  love_hmr = core.love_hmr,
  source_topology = core.source_topology,
  source_inventory = core.source_inventory,

  -- Testing & Test Host
  test = testModule,
  TestHost = testModule.createTestHost,
  act = testModule.act,
  render = testModule.render,
  create_test_root = testModule.render,

}

return Hydronium
