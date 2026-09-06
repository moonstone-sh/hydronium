;; -----------------------------------------------------------------------------
;; Tree-sitter Highlights Query for Hydronium LUAX
;; -----------------------------------------------------------------------------

;; Keywords
[
  "and"
  "do"
  "else"
  "elseif"
  "end"
  "for"
  "function"
  "if"
  "in"
  "local"
  "not"
  "or"
  "repeat"
  "return"
  "then"
  "until"
  "while"
] @keyword

(break_statement) @keyword

;; Constants & Literals
(nil) @constant.builtin
(boolean) @boolean
(number) @number
(string) @string
(multiline_string) @string

;; Punctuation & Delimiters
[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

[
  ","
  ";"
  ":"
  "."
] @punctuation.delimiter

;; Operators
[
  "+"
  "-"
  "*"
  "/"
  "//"
  "%"
  "^"
  "#"
  "=="
  "~="
  "<="
  ">="
  "<"
  ">"
  "="
  "&"
  "~"
  "|"
  "<<"
  ">>"
  ".."
] @operator

(vararg) @constant.builtin

;; Comments
(comment) @comment
(jsx_comment) @comment

;; Functions
(function_declaration
  name: (function_name
    (identifier) @function))

(function_declaration
  name: (function_name
    (identifier) @variable
    ":"
    (identifier) @function.method))

(local_function_declaration
  name: (identifier) @function)

(function_call
  callee: (identifier) @function.call)

(function_call
  method: (identifier) @function.method.call)

(parameter_list
  (identifier_list
    (identifier) @variable.parameter))

;; Variables & Identifiers
(identifier) @variable

;; =============================================================================
;; LUAX JSX-style Elements, Tags, and Attributes
;; =============================================================================

;; Tag Delimiters: <, >, </, />, <>
(opening_element
  [ "<" ">" ] @tag.delimiter)

(closing_element
  [ "</" ">" ] @tag.delimiter)

(self_closing_element
  [ "<" "/>" ] @tag.delimiter)

(opening_fragment
  [ "<" ">" ] @tag.delimiter)

(closing_fragment
  [ "</" ">" ] @tag.delimiter)

(self_closing_fragment
  [ "<" "/>" ] @tag.delimiter)

;; Tag Names
(opening_element
  name: (tag_expression) @tag)

(closing_element
  name: (tag_expression) @tag)

(self_closing_element
  name: (tag_expression) @tag)

;; Dotted Tag Names: d.button, UI.Card, etc.
(dotted_identifier
  object: (identifier) @module.builtin
  property: (identifier) @tag)

;; Hyphenated Custom Elements
(hyphenated_identifier) @tag

;; Attributes
(attribute
  name: (identifier) @tag.attribute)

(attribute
  name: (hyphenated_identifier) @tag.attribute)

(spread_attribute
  "..." @keyword.operator)

;; Text Children
(text_child) @string.special
