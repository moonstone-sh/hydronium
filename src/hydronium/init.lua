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

  -- Testing & Test Host
  test = testModule,
  TestHost = testModule.createTestHost,
  act = testModule.act,
  render = testModule.render,
  create_test_root = testModule.render,

  -- LUAX Compiler & Tooling
  luax = require("hydronium.luax"),

  -- Server-Side Rendering (SSR)
  server = require("hydronium.server"),
  ssr = require("hydronium.server"),
  renderToString = require("hydronium.server").render_to_string,
  render_to_string = require("hydronium.server").render_to_string,

  -- DOM Runtime Descriptors
  dom = require("hydronium.dom"),
  d = require("hydronium.dom"),
}

return Hydronium
