---@meta
--[[
  Hydronium Synthetic DOM Events Type Definitions
  Generated from WebRef specifications
--]]

--- Base synthetic event dispatched by Hydronium DOM listeners
---@class SyntheticEvent<T>
---@field target T # Event target node
---@field currentTarget T # Event listener target node
---@field type string # Event type name
---@field timeStamp number # Timestamp in milliseconds
---@field preventDefault fun(): void # Prevents default browser action
---@field stopPropagation fun(): void # Stops event propagation
---@field isDefaultPrevented fun(): boolean # Whether default action was prevented
---@field isPropagationStopped fun(): boolean # Whether propagation was stopped

--- Synthetic mouse event representing clicks, mouse movements, and buttons
---@class SyntheticMouseEvent<T> : SyntheticEvent<T>
---@field clientX number # X coordinate relative to the client viewport
---@field clientY number # Y coordinate relative to the client viewport
---@field screenX number # X coordinate relative to screen
---@field screenY number # Y coordinate relative to screen
---@field pageX number # X coordinate relative to full document
---@field pageY number # Y coordinate relative to full document
---@field button integer # Button pressed (0: left, 1: middle, 2: right)
---@field buttons integer # Bitmask of currently pressed buttons
---@field altKey boolean # Whether Alt key was held
---@field ctrlKey boolean # Whether Ctrl key was held
---@field metaKey boolean # Whether Meta / Command key was held
---@field shiftKey boolean # Whether Shift key was held

--- Synthetic keyboard event for keydown, keyup, keypress
---@class SyntheticKeyboardEvent<T> : SyntheticEvent<T>
---@field key string # Key value (e.g. 'Enter', 'a')
---@field code string # Physical key code (e.g. 'KeyA', 'Enter')
---@field altKey boolean # Alt key state
---@field ctrlKey boolean # Ctrl key state
---@field metaKey boolean # Meta / Command key state
---@field shiftKey boolean # Shift key state
---@field repeat boolean # Whether key is repeating

--- Synthetic focus and blur event
---@class SyntheticFocusEvent<T> : SyntheticEvent<T>
---@field relatedTarget any # Secondary target node

--- Synthetic input change event
---@class SyntheticInputEvent<T> : SyntheticEvent<T>
---@field data string? # Characters inserted
---@field inputType string # Type of input modification

--- Synthetic change event for form inputs
---@class SyntheticChangeEvent<T> : SyntheticEvent<T>
---@field value any # Current input value

--- Synthetic scroll wheel event
---@class SyntheticWheelEvent<T> : SyntheticMouseEvent<T>
---@field deltaX number # Horizontal scroll amount
---@field deltaY number # Vertical scroll amount
---@field deltaZ number # Z-axis scroll amount
---@field deltaMode integer # Unit of delta values

--- Synthetic multi-touch event
---@class SyntheticTouchEvent<T> : SyntheticEvent<T>
---@field touches any[] # Active touch points
---@field targetTouches any[] # Touch points originating on target
---@field changedTouches any[] # Touch points that contributed to event

--- Generic event handler callback type
---@alias EventHandler<E> fun(event: E): void
