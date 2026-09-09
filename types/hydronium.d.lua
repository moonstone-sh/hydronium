---@meta
--- Hydronium Type Definitions (EmmyLua / LuaLS)
--- Version 0.1.0

---@alias VNodeKind
---| '"ELEMENT"'
---| '"COMPONENT"'
---| '"FRAGMENT"'
---| '"TEXT"'
---| '"BOUNDARY"'

---@class Symbol
---@field name string
---@field __hydronium_symbol boolean

---@class VNode
---@field _typeof Symbol
---@field kind Symbol
---@field tag string|function|Symbol
---@field props table<string, any>
---@field children VNode[]
---@field key any
---@field ref? table|fun(instance: any) # ELEMENT vnodes ONLY -- the only kind with a host node to bind. On every other kind (COMPONENT, BOUNDARY, FRAGMENT, SUSPENSE, ISLAND, SCRIPT) `ref` stays in `props.ref` as an ordinary prop, for the consumer to forward explicitly (see element.lua's createElement)
---@field text? string
---@field hostNode? any
---@field componentInstance? ComponentInstance
--- Fine-grained reactive bindings (see docs/RECONCILIATION.md).
---@field reactiveGetter? fun(): any # TEXT vnodes only: the bare signal/computed accessor or plain function child this text node's content comes from. Its presence is what makes the reconciler create a per-node binding effect instead of a static text node. `text` still holds the current resolved value, so SSR needs to know nothing about this field.
---@field reactiveProps? table<string, fun(): any> # ELEMENT vnodes only: prop key -> the signal/computed accessor bound to it. Kept OFF `props`, which stays a fully-resolved plain snapshot; never populated for a COMPONENT, whose props must receive the accessor itself.
---@field _bindingEffect? Effect # Internal. The live Effect patching this TEXT vnode's host node; carried across reconciles while the getter identity is unchanged AND the effect is not disposed.
---@field _reactivePropEffects? table<string, Effect> # Internal. Per-prop-key binding effects for this ELEMENT vnode.
---@field _reactivePropsCurrent? table<string, any> # Internal. The ONE mutable "complete current props" snapshot shared by all of this vnode's reactive-prop effects, so every host.commitUpdate call gets a full prop set rather than a per-key delta. Rebuilt (in place) whenever the underlying prop set changes, so removed props are not resurrected.

---@class Scope
---@field _typeof Symbol
---@field parent? Scope
---@field children Scope[]
---@field cleanups (fun())[]
---@field isDisposed boolean
---@field defer fun(self: Scope, cleanupFn: fun())
---@field createChild fun(self: Scope): Scope
---@field dispose fun(self: Scope)

---@class ComponentInstance
---@field id number
---@field vnode VNode
---@field type function
---@field name string
---@field props table<string, any>
---@field parent? ComponentInstance
---@field depth number
---@field scope Scope
---@field context table<any, any>
---@field subTree? VNode
---@field hostNode? any
---@field isMounted boolean
---@field isDirty boolean
---@field isRendering boolean
---@field isDisposed boolean
---@field isErrorBoundary boolean
---@field boundaryError? any
---@field mount fun(self: ComponentInstance, parentHostNode: any, beforeChild: any, reconciler: any): any
---@field update fun(self: ComponentInstance, newProps?: table, reconciler?: any)
---@field unmount fun(self: ComponentInstance, reconciler?: any)
---@field render fun(self: ComponentInstance): VNode

---@class Host
---@field getRoot? fun(): any
---@field createInstance fun(tag: string, props: table): any
---@field createTextInstance fun(text: string): any
---@field appendChild fun(parent: any, child: any)
---@field insertBefore fun(parent: any, child: any, beforeChild: any)
---@field removeChild fun(parent: any, child: any)
---@field commitUpdate fun(instance: any, oldProps: table, newProps: table)
---@field commitTextUpdate fun(instance: any, oldText: string, newText: string)

---@class Ref<T>
---@field _typeof Symbol
---@field current T

---@class Context<T>
---@field _typeof Symbol
---@field id number
---@field defaultValue T
---@field Provider fun(props: { value: T, children?: any }): VNode

---@class Accessor<T>
---@overload fun(): T
---@overload fun(newVal: T|fun(prev: T): T): T
---@field get fun(): T
---@field set fun(newVal: T|fun(prev: T): T): T

---@alias Setter<T> fun(newVal: T|fun(prev: T): T): T

---@class Computed<T>
---@overload fun(): T
---@field get fun(): T
---@field dispose fun()

---@class Effect
---@field _typeof Symbol
---@field isDisposed boolean
---@field execute fun(self: Effect)
---@field dispose fun(self: Effect)

---@class HydroniumError
---@field isHydroniumError boolean
---@field phase "setup"|"render"|"commit"|"effect"|"cleanup"|"unknown"
---@field message string
---@field originalError any
---@field componentStack string[]

---@class TestRenderResult
---@field host Host
---@field root any
---@field container any
---@field rootHostNode any
---@field getVNode fun(): VNode
---@field unmount fun()
---@field update fun(newVNode: VNode): VNode
---@field toJSON fun(): table
---@field toTreeString fun(): string
---@field findByType fun(tag: string): any
---@field findAllByType fun(tag: string): any[]
---@field findByProp fun(prop: string, val: any): any
---@field getTextContent fun(): string

---@class HydroniumTest
---@field createTestHost fun(): Host
---@field act fun(fn: fun(...: any): any, ...: any): any
---@field render fun(vnode: VNode, options?: { host?: Host }): TestRenderResult
---@field toJSON fun(node: any): table
---@field toTreeString fun(node: any, indentLevel?: number): string
---@field findByType fun(root: any, tag: string): any
---@field findAllByType fun(root: any, tag: string): any[]
---@field findByProp fun(root: any, prop: string, val: any): any
---@field getTextContent fun(node: any): string

---@class SignalOptions<T>
---@field equals? boolean|(fun(a: T, b: T): boolean)
---@field name? string

---@class ErrorBoundaryProps
---@field fallback VNode|(fun(err: any, retry: fun()): VNode)
---@field onError? fun(err: any)
---@field children? any

--- "Can this subtree render right now, and what shows while it can't" --
--- see docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md. Independent of ErrorBoundary
--- (a failed Resource is an ErrorBoundary concern, not a Suspense one) and
--- of d.lua.island/d.js.island (client ownership is a separate axis).
---@class SuspenseProps
---@field fallback VNode
---@field children? any
--- Called synchronously, during SSR only, the moment this boundary
--- catches a suspension -- BEFORE it commits to `fallback`. If the
--- handler resolves (or rejects) the resource during the call, the
--- suspended subtree resumes exactly where `Resource:get()` left off,
--- already-buffered sibling output intact, and no fallback is ever
--- shown. If the resource is still pending when the handler returns,
--- the fallback is committed and this boundary is CLOSED: a resolve
--- arriving later can no longer contribute output (SSR writes a
--- sequential stream) and is reported through the suspense diagnostic
--- channel rather than written twice or silently dropped. So this is a
--- hook for a synchronously-satisfiable source (a warm cache, a
--- preloaded batch), not a general async escape hatch.
---@field onSuspend? fun(resource: HydroniumResource<any>)

---@alias HydroniumResourceStatus "pending"|"ready"|"failed"

---@class HydroniumResource<T>
---@field get fun(self: HydroniumResource<T>): T
---@field status fun(self: HydroniumResource<T>): HydroniumResourceStatus
---@field resolve fun(self: HydroniumResource<T>, value: T)
---@field reject fun(self: HydroniumResource<T>, err: any)

---@class Hydronium
---@field _VERSION string
---@field _DESCRIPTION string
---@field Fragment Symbol
---@field h fun(tag: string|function|Symbol, props?: table, ...: any): VNode
---@field createElement fun(tag: string|function|Symbol, props?: table, ...: any): VNode
---@field createTextVNode fun(text: string|number): VNode
---@field createSignal fun<T>(initialValue: T, options?: SignalOptions<T>): Accessor<T>, Setter<T>
---@field createComputed fun<T>(fn: fun(): T, options?: SignalOptions<T>): Computed<T>
---@field createEffect fun(fn: fun(): (fun()|nil)): Effect
---@field batch fun<T>(fn: fun(...: any): T, ...: any): T
---@field untrack fun<T>(fn: fun(...: any): T, ...: any): T
---@field createScope fun(fn?: fun(scope: Scope): any): any, Scope
---@field onCleanup fun(fn: fun())
---@field getScope fun(): Scope|nil
---@field runWithScope fun<T>(scope: Scope, fn: fun(...: any): T, ...: any): T
---@field createContext fun<T>(defaultValue: T): Context<T>
---@field useContext fun<T>(context: Context<T>): T
---@field createRef fun<T>(initialValue?: T): Ref<T>
---@field ErrorBoundary fun(props: ErrorBoundaryProps): VNode
---@field HydroniumError HydroniumError
---@field Suspense fun(props: SuspenseProps): VNode
---@field resource fun<T>(loader?: fun(): T): HydroniumResource<T>
---@field isSuspension fun(err: any): boolean
---@field dom HydroniumDOMDescriptors
---@field d HydroniumDOMDescriptors
---@field test HydroniumTest
---@field server HydroniumServer

local Hydronium = {}
return Hydronium
