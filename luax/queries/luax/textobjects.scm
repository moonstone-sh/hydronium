;; -----------------------------------------------------------------------------
;; Tree-sitter Textobjects Query for Hydronium LUAX
;; -----------------------------------------------------------------------------

;; Element Textobjects
(element_expression) @element.outer

(element_expression
  open: (_)
  .
  (_)* @element.inner
  .
  close: (_))

(fragment) @element.outer

(fragment
  open: (_)
  .
  (_)* @element.inner
  .
  close: (_))

;; Tag Textobjects
(opening_element) @tag.outer
(closing_element) @tag.outer
(self_closing_element) @tag.outer

;; Attribute Textobjects
(attribute) @attribute.outer
(attribute
  value: (_) @attribute.inner)
(spread_attribute) @attribute.outer

;; Function Textobjects
(function_declaration) @function.outer
(function_declaration
  parameters: (_)
  .
  (_)* @function.inner
  .
  "end")

(local_function_declaration) @function.outer
(local_function_declaration
  parameters: (_)
  .
  (_)* @function.inner
  .
  "end")

(function_definition) @function.outer
(function_definition
  parameters: (_)
  .
  (_)* @function.inner
  .
  "end")

;; Comment Textobjects
(comment) @comment.outer
(jsx_comment) @comment.outer
