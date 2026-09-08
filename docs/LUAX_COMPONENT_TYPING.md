# Typing your own component's props

This is the common case: an ordinary `.luax` component you write in your
own app, wanting real completion/hover on its props. If you're instead
building a new *host* (a `dom`/`ink`-style framework extension adding
brand-new intrinsic tags like `<ink.Box>`), see
`docs/LUAX_HOST_TYPE_AUTHORING.md` instead — that's a different, much
rarer case with different machinery, and this doc deliberately doesn't
cover it.

Follows this repo's own rule (`CLAUDE.md`'s "Trust issue in `docs/`"
section): only "VERIFIED" language backed by an actual run is used below.

## The answer: an ordinary `---@param` annotation, nothing else

```lua
---@class UserProfileProps
---@field name string
---@field age integer
---@field bio? string

---@param props UserProfileProps
local function UserProfile(props)
  return props.name -- or a real <Box>/<div>/whatever, this is illustrative
end

return <UserProfile name="Ada" age={36} />
```

That's the complete pipeline. No `hydronium.Intrinsic<P, H>`, no
`$$typeof`, no descriptor table, no `workspace.library` changes. **Verified
for real** via a headless `lua_ls`: with the cursor right after
`<UserProfile ` (nothing typed yet), `textDocument/completion` returned
exactly `name`, `age`, `bio?` — the real fields of `UserProfileProps`, not
`any`/generic buffer completion.

See `examples/ink_demo/demo.luax`'s `CounterLine` for a real, currently
checked-in, continuously-verified example of this — it takes a typed
`count: integer` prop, is used as `<CounterLine count={count} />`, and
`examples/ink_demo/run_luax.lua`'s compiled output is diffed byte-for-byte
against the plain-Lua `run.lua` version on every check, so this isn't a
prose-only claim about an example nobody runs.

## Why this needs nothing extra, when host intrinsics do

Every JSX tag lowers to one of two calls (see
`luax/src/hydronium_luax/luals/virtual_source.lua`'s `transform_element()`
— read there for the exact branch, not just this summary):

- **Bare tag** (`<button>`): `__luax_intrinsic.button({ ... })`
- **Everything else — dotted (`<d.button>`, `<ink.Box>`, `<UI.Card>`) or a
  plain identifier naming a local/global (`<UserProfile>`)**:
  `__luax_component(<the expression>, { ... })`

`__luax_component`'s own declared type
(`luax/types/luax.d.lua`):

```lua
---@generic TProps
---@param component fun(props: TProps): any
---@param props TProps
---@return any
function __luax_component(component, props, ...) end
```

`TProps` is inferred from whatever `component`'s own type turns out to
be. An ordinary Lua function annotated `---@param props UserProfileProps`
already *has* the type `fun(props: UserProfileProps): <its return type>`
-- a perfect structural match for `component`'s declared
`fun(props: TProps): any` shape, so `TProps` binds to `UserProfileProps`
immediately. Nothing else is involved.

A host's intrinsic descriptor (`ink.Box`, `d.button`) is different: its
real type is `hydronium.Intrinsic<P, H>`, a *class* with an `@overload`
annotation making it callable -- not literally a `fun(...)` type. LuaLS's
generic inference does not reliably bind `TProps` from an
`@overload`-carrying class the way it does from a plain function type,
which is why `docs/LUAX_HOST_TYPE_AUTHORING.md` has each host intrinsic
field declared as a **union** — `hydronium.Intrinsic<P, H> | fun(props?:
P, ...): LuaxElement` — specifically so the plain-function arm is there
for `__luax_component` to bind against. That extra step exists *only*
because a host intrinsic descriptor needs to also be a real, immutable,
`$$typeof`-carrying runtime object (for the reconciler to recognize it as
an intrinsic, not a component) — an ordinary component has no such
requirement, so it needs no such workaround.
