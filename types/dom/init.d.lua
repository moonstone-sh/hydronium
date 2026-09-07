---@meta "dom"
--[[
  Hydronium DOM Descriptors Type Definitions
  Exposes typed descriptor table 'd' where each property is typed as hydronium.Intrinsic<Props, HostElement>
--]]

--[[
  Island/Script authoring types (d.lua / d.js) -- see
  docs/HYDRONIUM_ISLANDS_SUSPENSE_V1.md. These are DOM-bound
  client-execution *descriptors*, not the interpreters themselves
  (hydronium.interpreter.lua / hydronium.interpreter.js, not implemented
  yet): typing them here costs nothing at runtime and requires no LUAX
  grammar changes -- `<d.lua.island>` is ordinary lexical tag resolution.
--]]

---@alias HydroniumHydratePolicy "load"|"visible"|"idle"|"interaction"|"manual"

---@class HydroniumLuaIslandProps
---@field hydrate? HydroniumHydratePolicy
---@field root? boolean
---@field key? string|number

---@class HydroniumJsIslandProps
---@field module string
---@field mode? "hydrate"|"mount"
---@field hydrate? HydroniumHydratePolicy
---@field props? table
---@field binds? table
---@field key? string|number

---@class HydroniumJsScriptProps
---@field src? string
---@field type? string
---@field strategy? string
---@field integrity? string
---@field binds? table

---@class HydroniumDOMLuaNamespace
---@field island hydronium.Intrinsic<HydroniumLuaIslandProps, any> | fun(props?: HydroniumLuaIslandProps, ...: any): LuaxElement
---@field mount fun(vnode: LuaxElement): LuaxElement

---@class HydroniumDOMJsNamespace
---@field island hydronium.Intrinsic<HydroniumJsIslandProps, any> | fun(props?: HydroniumJsIslandProps, ...: any): LuaxElement
---@field script hydronium.Intrinsic<HydroniumJsScriptProps, any> | fun(props?: HydroniumJsScriptProps): LuaxElement

---@class HydroniumDOMDescriptors
---@field d HydroniumDOMDescriptors
---@field createIntrinsic fun(tag: string): hydronium.Intrinsic<any, any>
---@field lua HydroniumDOMLuaNamespace
---@field js HydroniumDOMJsNamespace
---@field [string] hydronium.Intrinsic<any, any>
---@field button hydronium.Intrinsic<HTMLButtonProps, HTMLButtonElement> | fun(props?: HTMLButtonProps, ...: any): LuaxElement
---@field input hydronium.Intrinsic<HTMLInputProps, HTMLInputElement> | fun(props?: HTMLInputProps, ...: any): LuaxElement
---@field h1 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement>
---@field h2 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement>
---@field h3 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement>
---@field h4 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement>
---@field h5 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement>
---@field h6 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement>
---@field div hydronium.Intrinsic<HTMLDivProps, HTMLDivElement>
---@field span hydronium.Intrinsic<HTMLSpanProps, HTMLSpanElement>
---@field main hydronium.Intrinsic<HTMLMainProps, HTMLElement>
---@field section hydronium.Intrinsic<HTMLSectionProps, HTMLElement>
---@field a hydronium.Intrinsic<HTMLAnchorProps, HTMLAnchorElement>
---@field p hydronium.Intrinsic<HTMLParagraphProps, HTMLParagraphElement>
---@field form hydronium.Intrinsic<HTMLFormProps, HTMLFormElement>
---@field img hydronium.Intrinsic<HTMLImageProps, HTMLImageElement>
---@field textarea hydronium.Intrinsic<HTMLTextAreaProps, HTMLTextAreaElement>
---@field select hydronium.Intrinsic<HTMLSelectProps, HTMLSelectElement>
---@field option hydronium.Intrinsic<HTMLOptionProps, HTMLOptionElement>
---@field label hydronium.Intrinsic<HTMLLabelProps, HTMLLabelElement>
---@field ul hydronium.Intrinsic<HTMLUListProps, HTMLUListElement>
---@field ol hydronium.Intrinsic<HTMLOListProps, HTMLOListElement>
---@field li hydronium.Intrinsic<HTMLLIProps, HTMLLIElement>
---@field header hydronium.Intrinsic<HTMLHeaderProps, HTMLElement>
---@field footer hydronium.Intrinsic<HTMLFooterProps, HTMLElement>
---@field nav hydronium.Intrinsic<HTMLNavProps, HTMLElement>
---@field aside hydronium.Intrinsic<HTMLAsideProps, HTMLElement>
---@field article hydronium.Intrinsic<HTMLArticleProps, HTMLElement>
---@field table hydronium.Intrinsic<HTMLTableProps, HTMLTableElement>
---@field thead hydronium.Intrinsic<HTMLTableSectionProps, HTMLTableSectionElement>
---@field tbody hydronium.Intrinsic<HTMLTableSectionProps, HTMLTableSectionElement>
---@field tfoot hydronium.Intrinsic<HTMLTableSectionProps, HTMLTableSectionElement>
---@field tr hydronium.Intrinsic<HTMLTableRowProps, HTMLTableRowElement>
---@field th hydronium.Intrinsic<HTMLTableCellProps, HTMLTableCellElement>
---@field td hydronium.Intrinsic<HTMLTableCellProps, HTMLTableCellElement>
---@field canvas hydronium.Intrinsic<HTMLCanvasProps, HTMLCanvasElement>
---@field audio hydronium.Intrinsic<HTMLAudioProps, HTMLAudioElement>
---@field video hydronium.Intrinsic<HTMLVideoProps, HTMLVideoElement>
---@field pre hydronium.Intrinsic<HTMLPreProps, HTMLElement>
---@field code hydronium.Intrinsic<HTMLCodeProps, HTMLElement>
---@field dialog hydronium.Intrinsic<HTMLDialogProps, HTMLDialogElement>
---@field svg hydronium.Intrinsic<SVGSVGProps, SVGElement>
---@field path hydronium.Intrinsic<SVGPathProps, SVGElement>
---@field circle hydronium.Intrinsic<SVGCircleProps, SVGElement>
---@field rect hydronium.Intrinsic<SVGRectProps, SVGElement>
---@field g hydronium.Intrinsic<SVGGProps, SVGElement>
---@field text hydronium.Intrinsic<SVGTextProps, SVGElement>
---@field abbr hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field address hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field area hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field b hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field base hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field bdi hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field bdo hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field blockquote hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field body hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field br hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field caption hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field cite hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field col hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field colgroup hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field data hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field datalist hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field dd hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field del hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field details hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field dfn hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field dl hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field dt hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field em hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field embed hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field fieldset hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field figcaption hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field figure hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field head hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field hgroup hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field hr hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field html hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field i hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field iframe hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field ins hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field kbd hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field legend hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field link hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field map hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field mark hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field menu hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field meta hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field meter hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field noscript hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field object hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field optgroup hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field output hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field picture hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field progress hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field q hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field rp hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field rt hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field ruby hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field s hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field samp hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field script hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field search hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field slot hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field small hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field source hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field strong hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field style hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field sub hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field summary hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field sup hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field template hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field time hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field title hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field track hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field u hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field var hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field wbr hydronium.Intrinsic<HTMLAttributes, HTMLElement>
---@field line hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field polyline hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field polygon hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field tspan hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field defs hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field use hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field symbol hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field clipPath hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field mask hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field pattern hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field linearGradient hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field radialGradient hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field stop hydronium.Intrinsic<SVGAttributes, SVGElement>
---@field image hydronium.Intrinsic<SVGAttributes, SVGElement>

--- Immutable descriptor table 'd' exported by hydronium.dom
---@type HydroniumDOMDescriptors
local dom = {}

---@type hydronium.Intrinsic<HTMLButtonProps, HTMLButtonElement>
dom.button = ...
---@type hydronium.Intrinsic<HTMLInputProps, HTMLInputElement>
dom.input = ...
---@type hydronium.Intrinsic<HTMLDivProps, HTMLDivElement>
dom.div = ...
---@type hydronium.Intrinsic<HTMLSpanProps, HTMLSpanElement>
dom.span = ...
---@type hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement>
dom.h1 = ...
---@type hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement>
dom.h2 = ...
---@type hydronium.Intrinsic<HTMLParagraphProps, HTMLParagraphElement>
dom.p = ...
---@type hydronium.Intrinsic<HTMLAnchorProps, HTMLAnchorElement>
dom.a = ...
---@type hydronium.Intrinsic<HTMLFormProps, HTMLFormElement>
dom.form = ...
---@type hydronium.Intrinsic<HTMLMainProps, HTMLElement>
dom.main = ...
---@type hydronium.Intrinsic<HTMLSectionProps, HTMLElement>
dom.section = ...
---@type hydronium.Intrinsic<SVGSVGProps, SVGElement>
dom.svg = ...

--- Global descriptor table 'd'
---@type HydroniumDOMDescriptors
d = dom
dom.d = dom

return dom
