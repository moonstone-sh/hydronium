--[[
  Hydronium Component Model & Lifecycle
  Component instances, reactive render tracking, context inheritance,
  and ErrorBoundary integration.
  Compatible with Lua 5.1, 5.2, 5.3, 5.4, and LuaJIT.
--]]

local symbols = require("hydronium.core.symbols")
local errors = require("hydronium.core.errors")
local scopeModule = require("hydronium.core.scope")
local scheduler = require("hydronium.core.scheduler")
local contextModule = require("hydronium.core.context")
local graph = require("hydronium.signals.graph")

local unpack = table.unpack or unpack

local componentModule = {}

local ComponentInstance = {}
ComponentInstance.__index = ComponentInstance

local nextComponentId = 0

function ComponentInstance.new(vnode, parentComponent, host)
  nextComponentId = nextComponentId + 1
  local self = setmetatable({}, ComponentInstance)

  self.id = nextComponentId
  self.vnode = vnode
  self.type = vnode.tag

  local compName = "Component"
  if type(vnode.tag) == "table" and vnode.tag.name then
    compName = tostring(vnode.tag.name)
  elseif type(vnode.tag) == "function" then
    local info = debug.getinfo(vnode.tag, "n")
    if info and info.name and info.name ~= "" then
      compName = info.name
    end
  end
  self.name = compName

  self.props = vnode.props or {}
  self.parent = parentComponent
  self.host = host
  self.depth = parentComponent and (parentComponent.depth + 1) or 0

  -- Hierarchical scope
  local parentScope = parentComponent and parentComponent.scope or nil
  self.scope = scopeModule.Scope.new(parentScope)

  -- Hierarchical context
  if parentComponent and parentComponent.context then
    self.context = setmetatable({}, { __index = parentComponent.context })
  else
    self.context = setmetatable({}, { __index = contextModule.getCurrentContextMap() })
  end

  -- If this component is a Context Provider, register its provided value
  if type(vnode.tag) == "table" and vnode.tag.__context then
    local ctx = vnode.tag.__context
    self.context[ctx] = self.props.value
  end

  self.isErrorBoundary = (vnode.kind == symbols.BOUNDARY)
  self.boundaryError = nil
  self.subTree = nil
  self.hostNode = nil
  self.parentHostNode = nil
  self.isMounted = false
  self.isDirty = false
  self.isRendering = false
  self.isDisposed = false
  self.renderFn = nil

  -- Reactive observer dependencies
  self.sources = {}

  return self
end

function ComponentInstance:findNearestBoundary()
  local curr = self.parent
  while curr do
    if curr.isErrorBoundary then
      return curr
    end
    curr = curr.parent
  end
  return nil
end

function ComponentInstance:handleError(err)
  local boundary = self:findNearestBoundary()
  if boundary then
    boundary:catchError(err)
  else
    error(tostring(err), 0)
  end
end

function ComponentInstance:catchError(err)
  self.boundaryError = err

  if self.props.onError and type(self.props.onError) == "function" then
    pcall(self.props.onError, err)
  end

  if self.isMounted and not self.isMounting then
    self.isDirty = true
    scheduler.scheduleRender(self)
  end
end

function ComponentInstance:markDirty()
  if not self.isDirty and self.isMounted then
    self.isDirty = true
    scheduler.scheduleRender(self)
  end
end

function ComponentInstance:notify()
  self:markDirty()
end

--- Execute render function inside reactive observer and scope.
function ComponentInstance:render()
  self.isRendering = true
  scheduler.setCurrentRenderingComponent(self)
  scheduler.pushComponentStack(self.name)

  local prevContextMap = contextModule.getCurrentContextMap()
  contextModule.pushContext(self.context)

  local ok, renderedVNode = pcall(function()
    return scopeModule.runWithScope(self.scope, function()
      return graph.runObserver(self, function()
        if self.isErrorBoundary then
          if self.boundaryError ~= nil then
            -- ErrorBoundary fallback rendering
            local fallback = self.props.fallback
            if type(fallback) == "function" then
              local retry = function()
                self.boundaryError = nil
                self.isDirty = true
                scheduler.scheduleRender(self)
              end
              -- If fallback throws, bubble to parent ErrorBoundary (Amendment 2)
              local fbOk, fbRes = pcall(fallback, self.boundaryError, retry)
              if not fbOk then
                -- Fallback failed! Bubble to enclosing parent boundary
                local parentBoundary = self:findNearestBoundary()
                if parentBoundary then
                  parentBoundary:catchError(fbRes)
                  return nil
                else
                  error(fbRes, 0)
                end
              end
              return fbRes
            else
              return fallback
            end
          else
            local element = require("hydronium.core.element")
            return element.createElement(symbols.FRAGMENT, nil, self.props.children or self.vnode.children)
          end
        end

        if self.scope and self.scope.resetIdCounters then
          self.scope:resetIdCounters()
        end

        if not self.renderFn then
          -- Initial invocation
          local initialRes = self.type(self.props, self.scope)
          if type(initialRes) == "function" then
            self.renderFn = initialRes
            return self.renderFn(self.props, self.scope)
          else
            self.renderFn = self.type
            return initialRes
          end
        else
          return self.renderFn(self.props, self.scope)
        end
      end)
    end)
  end)

  contextModule.popContext()
  scheduler.popComponentStack()
  scheduler.setCurrentRenderingComponent(nil)
  self.isRendering = false

  if not ok then
    local phaseErr = errors.wrapPhaseError("render", renderedVNode, self.name, scheduler.getComponentStack())
    self:handleError(phaseErr)
    return nil
  end

  return renderedVNode
end

function ComponentInstance:mount(parentHostNode, beforeChild, reconciler)
  self.parentHostNode = parentHostNode
  self.reconciler = reconciler or self.reconciler
  self.isMounting = true
  self.isMounted = true

  local renderedVNode = self:render()

  if renderedVNode then
    self.subTree = renderedVNode
    self.hostNode = self.reconciler:mount(renderedVNode, parentHostNode, beforeChild, self)
  end

  if self.isErrorBoundary and self.boundaryError ~= nil and not self.hostNode then
    self.isDirty = false
    local fallbackVNode = self:render()
    if fallbackVNode then
      self.subTree = fallbackVNode
      self.hostNode = self.reconciler:mount(fallbackVNode, parentHostNode, beforeChild, self)
    end
  else
    self.isDirty = false
  end

  self.isMounting = false
  return self.hostNode
end

function ComponentInstance:update(newProps, reconciler)
  if not self.isMounted or self.isDisposed then
    return
  end

  if newProps then
    self.props = newProps
    local ctx = nil
    if type(self.type) == "table" and self.type.__context then
      ctx = self.type.__context
    elseif type(self.vnode) == "table" and type(self.vnode.tag) == "table" and self.vnode.tag.__context then
      ctx = self.vnode.tag.__context
    end
    if ctx then
      self.context[ctx] = self.props.value
    end
  end

  self.isDirty = false
  local nextSubTree = self:render()

  local rec = reconciler or self.reconciler
  if not rec then
    rec = require("hydronium.core.reconciler").getDefaultReconciler()
  end

  if self.subTree and nextSubTree then
    self.subTree = rec:reconcile(self.parentHostNode, self.subTree, nextSubTree, self)
    self.hostNode = rec:getHostNode(self.subTree)
  elseif nextSubTree and not self.subTree then
    self.subTree = nextSubTree
    self.hostNode = rec:mount(nextSubTree, self.parentHostNode, nil, self)
  elseif self.subTree and not nextSubTree then
    rec:unmount(self.subTree)
    self.subTree = nil
    self.hostNode = nil
  end
end

function ComponentInstance:unmount(reconciler)
  if self.isDisposed then
    return
  end
  self.isDisposed = true
  self.isMounted = false

  -- Unsubscribe from reactive sources
  graph.cleanupObserverSources(self)

  local rec = reconciler or self.reconciler
  if not rec then
    rec = require("hydronium.core.reconciler").getDefaultReconciler()
  end

  -- Unmount child subtree
  if self.subTree and rec then
    rec:unmount(self.subTree)
    self.subTree = nil
  end

  -- Dispose component scope (LIFO cleanups with pcall)
  local ok, err = pcall(function()
    self.scope:dispose()
  end)
  if not ok then
    self:handleError(err)
  end
end

componentModule.ComponentInstance = ComponentInstance

return componentModule
