;; -----------------------------------------------------------------------------
;; Tree-sitter Indents Query for Hydronium LUAX
;; -----------------------------------------------------------------------------

[
  (do_statement)
  (while_statement)
  (repeat_statement)
  (if_statement)
  (elseif_clause)
  (else_clause)
  (for_numeric_statement)
  (for_generic_statement)
  (function_declaration)
  (local_function_declaration)
  (function_definition)
  (table_constructor)
  (parenthesized_expression)
  (element_expression)
  (fragment)
  (opening_element)
] @indent.begin

[
  "end"
  "until"
  "}"
  ")"
  "]"
  (closing_element)
  (closing_fragment)
] @indent.end

(attribute) @indent.align
