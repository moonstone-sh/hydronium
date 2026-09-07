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
---@field [string] hydronium.Intrinsic<any, any> | fun(props?: any, ...: any): LuaxElement
---@field button hydronium.Intrinsic<HTMLButtonProps, HTMLButtonElement> | fun(props?: HTMLButtonProps, ...: any): LuaxElement
---@field input hydronium.Intrinsic<HTMLInputProps, HTMLInputElement> | fun(props?: HTMLInputProps, ...: any): LuaxElement
---@field h1 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement> | fun(props?: HTMLHeadingProps, ...: any): LuaxElement
---@field h2 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement> | fun(props?: HTMLHeadingProps, ...: any): LuaxElement
---@field h3 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement> | fun(props?: HTMLHeadingProps, ...: any): LuaxElement
---@field h4 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement> | fun(props?: HTMLHeadingProps, ...: any): LuaxElement
---@field h5 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement> | fun(props?: HTMLHeadingProps, ...: any): LuaxElement
---@field h6 hydronium.Intrinsic<HTMLHeadingProps, HTMLHeadingElement> | fun(props?: HTMLHeadingProps, ...: any): LuaxElement
---@field div hydronium.Intrinsic<HTMLDivProps, HTMLDivElement> | fun(props?: HTMLDivProps, ...: any): LuaxElement
---@field span hydronium.Intrinsic<HTMLSpanProps, HTMLSpanElement> | fun(props?: HTMLSpanProps, ...: any): LuaxElement
---@field main hydronium.Intrinsic<HTMLMainProps, HTMLElement> | fun(props?: HTMLMainProps, ...: any): LuaxElement
---@field section hydronium.Intrinsic<HTMLSectionProps, HTMLElement> | fun(props?: HTMLSectionProps, ...: any): LuaxElement
---@field a hydronium.Intrinsic<HTMLAnchorProps, HTMLAnchorElement> | fun(props?: HTMLAnchorProps, ...: any): LuaxElement
---@field p hydronium.Intrinsic<HTMLParagraphProps, HTMLParagraphElement> | fun(props?: HTMLParagraphProps, ...: any): LuaxElement
---@field form hydronium.Intrinsic<HTMLFormProps, HTMLFormElement> | fun(props?: HTMLFormProps, ...: any): LuaxElement
---@field img hydronium.Intrinsic<HTMLImageProps, HTMLImageElement> | fun(props?: HTMLImageProps, ...: any): LuaxElement
---@field textarea hydronium.Intrinsic<HTMLTextAreaProps, HTMLTextAreaElement> | fun(props?: HTMLTextAreaProps, ...: any): LuaxElement
---@field select hydronium.Intrinsic<HTMLSelectProps, HTMLSelectElement> | fun(props?: HTMLSelectProps, ...: any): LuaxElement
---@field option hydronium.Intrinsic<HTMLOptionProps, HTMLOptionElement> | fun(props?: HTMLOptionProps, ...: any): LuaxElement
---@field label hydronium.Intrinsic<HTMLLabelProps, HTMLLabelElement> | fun(props?: HTMLLabelProps, ...: any): LuaxElement
---@field ul hydronium.Intrinsic<HTMLUListProps, HTMLUListElement> | fun(props?: HTMLUListProps, ...: any): LuaxElement
---@field ol hydronium.Intrinsic<HTMLOListProps, HTMLOListElement> | fun(props?: HTMLOListProps, ...: any): LuaxElement
---@field li hydronium.Intrinsic<HTMLLIProps, HTMLLIElement> | fun(props?: HTMLLIProps, ...: any): LuaxElement
---@field header hydronium.Intrinsic<HTMLHeaderProps, HTMLElement> | fun(props?: HTMLHeaderProps, ...: any): LuaxElement
---@field footer hydronium.Intrinsic<HTMLFooterProps, HTMLElement> | fun(props?: HTMLFooterProps, ...: any): LuaxElement
---@field nav hydronium.Intrinsic<HTMLNavProps, HTMLElement> | fun(props?: HTMLNavProps, ...: any): LuaxElement
---@field aside hydronium.Intrinsic<HTMLAsideProps, HTMLElement> | fun(props?: HTMLAsideProps, ...: any): LuaxElement
---@field article hydronium.Intrinsic<HTMLArticleProps, HTMLElement> | fun(props?: HTMLArticleProps, ...: any): LuaxElement
---@field table hydronium.Intrinsic<HTMLTableProps, HTMLTableElement> | fun(props?: HTMLTableProps, ...: any): LuaxElement
---@field thead hydronium.Intrinsic<HTMLTableSectionProps, HTMLTableSectionElement> | fun(props?: HTMLTableSectionProps, ...: any): LuaxElement
---@field tbody hydronium.Intrinsic<HTMLTableSectionProps, HTMLTableSectionElement> | fun(props?: HTMLTableSectionProps, ...: any): LuaxElement
---@field tfoot hydronium.Intrinsic<HTMLTableSectionProps, HTMLTableSectionElement> | fun(props?: HTMLTableSectionProps, ...: any): LuaxElement
---@field tr hydronium.Intrinsic<HTMLTableRowProps, HTMLTableRowElement> | fun(props?: HTMLTableRowProps, ...: any): LuaxElement
---@field th hydronium.Intrinsic<HTMLTableCellProps, HTMLTableCellElement> | fun(props?: HTMLTableCellProps, ...: any): LuaxElement
---@field td hydronium.Intrinsic<HTMLTableCellProps, HTMLTableCellElement> | fun(props?: HTMLTableCellProps, ...: any): LuaxElement
---@field canvas hydronium.Intrinsic<HTMLCanvasProps, HTMLCanvasElement> | fun(props?: HTMLCanvasProps, ...: any): LuaxElement
---@field audio hydronium.Intrinsic<HTMLAudioProps, HTMLAudioElement> | fun(props?: HTMLAudioProps, ...: any): LuaxElement
---@field video hydronium.Intrinsic<HTMLVideoProps, HTMLVideoElement> | fun(props?: HTMLVideoProps, ...: any): LuaxElement
---@field pre hydronium.Intrinsic<HTMLPreProps, HTMLElement> | fun(props?: HTMLPreProps, ...: any): LuaxElement
---@field code hydronium.Intrinsic<HTMLCodeProps, HTMLElement> | fun(props?: HTMLCodeProps, ...: any): LuaxElement
---@field dialog hydronium.Intrinsic<HTMLDialogProps, HTMLDialogElement> | fun(props?: HTMLDialogProps, ...: any): LuaxElement
---@field svg hydronium.Intrinsic<SVGSVGProps, SVGElement> | fun(props?: SVGSVGProps, ...: any): LuaxElement
---@field path hydronium.Intrinsic<SVGPathProps, SVGElement> | fun(props?: SVGPathProps, ...: any): LuaxElement
---@field circle hydronium.Intrinsic<SVGCircleProps, SVGElement> | fun(props?: SVGCircleProps, ...: any): LuaxElement
---@field rect hydronium.Intrinsic<SVGRectProps, SVGElement> | fun(props?: SVGRectProps, ...: any): LuaxElement
---@field g hydronium.Intrinsic<SVGGProps, SVGElement> | fun(props?: SVGGProps, ...: any): LuaxElement
---@field text hydronium.Intrinsic<SVGTextProps, SVGElement> | fun(props?: SVGTextProps, ...: any): LuaxElement
---@field abbr hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field address hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field area hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field b hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field base hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field bdi hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field bdo hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field blockquote hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field body hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field br hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field caption hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field cite hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field col hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field colgroup hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field data hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field datalist hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field dd hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field del hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field details hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field dfn hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field dl hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field dt hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field em hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field embed hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field fieldset hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field figcaption hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field figure hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field head hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field hgroup hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field hr hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field html hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field i hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field iframe hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field ins hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field kbd hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field legend hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field link hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field map hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field mark hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field menu hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field meta hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field meter hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field noscript hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field object hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field optgroup hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field output hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field picture hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field progress hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field q hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field rp hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field rt hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field ruby hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field s hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field samp hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field script hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field search hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field slot hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field small hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field source hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field strong hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field style hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field sub hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field summary hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field sup hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field template hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field time hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field title hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field track hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field u hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field var hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field wbr hydronium.Intrinsic<HTMLAttributes, HTMLElement> | fun(props?: HTMLAttributes, ...: any): LuaxElement
---@field line hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field polyline hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field polygon hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field tspan hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field defs hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field use hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field symbol hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field clipPath hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field mask hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field pattern hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field linearGradient hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field radialGradient hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field stop hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement
---@field image hydronium.Intrinsic<SVGAttributes, SVGElement> | fun(props?: SVGAttributes, ...: any): LuaxElement

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
