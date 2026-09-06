---@meta
--[[
  Hydronium DOM Descriptors Type Definitions
  Exposes typed descriptor table 'd' where each property is typed as hydronium.Intrinsic<Props, HostElement>
--]]

---@class HydroniumDOMDescriptors
---@field d HydroniumDOMDescriptors
---@field createIntrinsic fun(tag: string): hydronium.Intrinsic<any, any>
---@field button hydronium.Intrinsic<HTMLButtonProps, HTMLButtonElement>
---@field input hydronium.Intrinsic<HTMLInputProps, HTMLInputElement>
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

--- Immutable descriptor table 'd' exported by hydronium.dom
---@type HydroniumDOMDescriptors
d = {}

local dom = {}
dom.d = d
return dom
