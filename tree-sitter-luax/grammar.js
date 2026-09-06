/**
 * Tree-sitter Grammar for Hydronium LUAX (.luax)
 * Extends standard Lua syntax with JSX-like elements, fragments,
 * embedded expressions, spread attributes, dotted tags, and resilient error recovery.
 */

module.exports = grammar({
  name: 'luax',

  extras: $ => [
    /\s/,
    $.comment,
    $.jsx_comment,
  ],

  conflicts: $ => [
    [$._prefix_expression, $.expression],
    [$._prefix_expression, $.tag_expression],
    [$.tag_expression, $.expression],
    [$.attribute, $._expression_container],
    [$.function_call, $._prefix_expression],
    [$.statement, $._prefix_expression],
    [$.identifier_list],
  ],

  word: $ => $.identifier,

  rules: {
    program: $ => seq(
      optional($.shebang),
      repeat($.statement),
      optional($.return_statement)
    ),

    shebang: $ => /#![^\r\n]*/,

    // =========================================================================
    // Statements
    // =========================================================================
    statement: $ => choice(
      $.variable_declaration,
      $.local_variable_declaration,
      $.function_call,
      $.function_declaration,
      $.local_function_declaration,
      $.do_statement,
      $.while_statement,
      $.repeat_statement,
      $.if_statement,
      $.for_numeric_statement,
      $.for_generic_statement,
      $.break_statement,
      $.empty_statement
    ),

    empty_statement: $ => ';',

    break_statement: $ => 'break',

    return_statement: $ => prec.right(seq(
      'return',
      optional($.expression_list),
      optional(';')
    )),

    expression_list: $ => seq(
      $.expression,
      repeat(seq(',', $.expression))
    ),

    variable_declaration: $ => prec.right(seq(
      $.variable_list,
      '=',
      $.expression_list
    )),

    variable_list: $ => seq(
      $._variable,
      repeat(seq(',', $._variable))
    ),

    local_variable_declaration: $ => prec.right(seq(
      'local',
      $.identifier_list,
      optional(seq('=', $.expression_list))
    )),

    identifier_list: $ => seq(
      $.identifier,
      repeat(seq(',', $.identifier))
    ),

    do_statement: $ => seq(
      'do',
      repeat($.statement),
      optional($.return_statement),
      'end'
    ),

    while_statement: $ => seq(
      'while',
      field('condition', $.expression),
      'do',
      repeat($.statement),
      optional($.return_statement),
      'end'
    ),

    repeat_statement: $ => seq(
      'repeat',
      repeat($.statement),
      optional($.return_statement),
      'until',
      field('condition', $.expression)
    ),

    if_statement: $ => seq(
      'if',
      field('condition', $.expression),
      'then',
      repeat($.statement),
      repeat($.elseif_clause),
      optional($.else_clause),
      'end'
    ),

    elseif_clause: $ => seq(
      'elseif',
      field('condition', $.expression),
      'then',
      repeat($.statement)
    ),

    else_clause: $ => seq(
      'else',
      repeat($.statement)
    ),

    for_numeric_statement: $ => seq(
      'for',
      field('var', $.identifier),
      '=',
      field('start', $.expression),
      ',',
      field('stop', $.expression),
      optional(seq(',', field('step', $.expression))),
      'do',
      repeat($.statement),
      optional($.return_statement),
      'end'
    ),

    for_generic_statement: $ => seq(
      'for',
      field('vars', $.identifier_list),
      'in',
      field('iterators', $.expression_list),
      'do',
      repeat($.statement),
      optional($.return_statement),
      'end'
    ),

    function_declaration: $ => seq(
      'function',
      field('name', $.function_name),
      field('parameters', $.parameter_list),
      repeat($.statement),
      optional($.return_statement),
      'end'
    ),

    local_function_declaration: $ => seq(
      'local',
      'function',
      field('name', $.identifier),
      field('parameters', $.parameter_list),
      repeat($.statement),
      optional($.return_statement),
      'end'
    ),

    function_name: $ => seq(
      $.identifier,
      repeat(seq('.', $.identifier)),
      optional(seq(':', $.identifier))
    ),

    parameter_list: $ => seq(
      '(',
      optional(choice(
        seq($.identifier_list, optional(seq(',', '...'))),
        '...'
      )),
      ')'
    ),

    // =========================================================================
    // Expressions
    // =========================================================================
    expression: $ => choice(
      $.nil,
      $.boolean,
      $.number,
      $.string,
      $.vararg,
      $.table_constructor,
      $.function_definition,
      $._prefix_expression,
      $.binary_expression,
      $.unary_expression,
      // LUAX specific syntax elements
      $.element_expression,
      $.fragment
    ),

    vararg: $ => '...',

    _variable: $ => choice(
      $.identifier,
      $.field_expression,
      $.index_expression
    ),

    _prefix_expression: $ => choice(
      $._variable,
      $.function_call,
      $.parenthesized_expression
    ),

    parenthesized_expression: $ => seq('(', $.expression, ')'),

    field_expression: $ => prec.left(1, seq(
      field('object', $._prefix_expression),
      '.',
      field('property', $.identifier)
    )),

    index_expression: $ => prec.left(1, seq(
      field('object', $._prefix_expression),
      '[',
      field('index', $.expression),
      ']'
    )),

    function_call: $ => prec.left(2, choice(
      seq(
        field('callee', $._prefix_expression),
        field('arguments', $.argument_list)
      ),
      seq(
        field('receiver', $._prefix_expression),
        ':',
        field('method', $.identifier),
        field('arguments', $.argument_list)
      )
    )),

    argument_list: $ => choice(
      seq('(', optional($.expression_list), ')'),
      $.table_constructor,
      $.string
    ),

    function_definition: $ => seq(
      'function',
      field('parameters', $.parameter_list),
      repeat($.statement),
      optional($.return_statement),
      'end'
    ),

    unary_expression: $ => prec.right(8, seq(
      choice('not', '#', '-', '~'),
      field('argument', $.expression)
    )),

    binary_expression: $ => {
      const table = [
        [choice('or'), 1],
        [choice('and'), 2],
        [choice('<', '<=', '>', '>=', '==', '~='), 3],
        [choice('|'), 4],
        [choice('~'), 5],
        [choice('&'), 6],
        [choice('<<', '>>'), 7],
        [choice('..'), 8, 'right'],
        [choice('+', '-'), 9],
        [choice('*', '/', '//', '%'), 10],
        [choice('^'), 11, 'right'],
      ];

      return choice(...table.map(([operator, precedence, associativity]) => {
        const fn = associativity === 'right' ? prec.right : prec.left;
        return fn(precedence, seq(
          field('left', $.expression),
          field('operator', operator),
          field('right', $.expression)
        ));
      }));
    },

    table_constructor: $ => seq(
      '{',
      optional($.field_list),
      '}'
    ),

    field_list: $ => seq(
      $.field,
      repeat(seq(choice(',', ';'), $.field)),
      optional(choice(',', ';'))
    ),

    field: $ => choice(
      seq('[', field('key', $.expression), ']', '=', field('value', $.expression)),
      seq(field('key', $.identifier), '=', field('value', $.expression)),
      field('value', $.expression)
    ),

    // =========================================================================
    // LUAX JSX-style Elements, Fragments, Attributes & Text
    // =========================================================================

    element_expression: $ => choice(
      seq(
        field('open', $.opening_element),
        repeat($._child),
        field('close', $.closing_element)
      ),
      $.self_closing_element
    ),

    opening_element: $ => prec(10, seq(
      '<',
      field('name', $.tag_expression),
      repeat($._attribute),
      '>'
    )),

    closing_element: $ => seq(
      '</',
      field('name', $.tag_expression),
      '>'
    ),

    self_closing_element: $ => prec(10, seq(
      '<',
      field('name', $.tag_expression),
      repeat($._attribute),
      '/>'
    )),

    tag_expression: $ => choice(
      $.identifier,
      $.dotted_identifier,
      $.hyphenated_identifier
    ),

    dotted_identifier: $ => prec.left(seq(
      field('object', choice($.identifier, $.dotted_identifier)),
      '.',
      field('property', $.identifier)
    )),

    hyphenated_identifier: $ => /[a-zA-Z_][a-zA-Z0-9_]*-[a-zA-Z0-9_\-]*/,

    _attribute: $ => choice(
      $.attribute,
      $.spread_attribute
    ),

    attribute: $ => seq(
      field('name', choice($.identifier, $.hyphenated_identifier)),
      optional(seq(
        '=',
        field('value', choice(
          $.string,
          $._expression_container
        ))
      ))
    ),

    spread_attribute: $ => seq(
      '{',
      '...',
      $.expression,
      '}'
    ),

    fragment: $ => choice(
      seq(
        field('open', $.opening_fragment),
        repeat($._child),
        field('close', $.closing_fragment)
      ),
      $.self_closing_fragment
    ),

    opening_fragment: $ => seq('<', '>'),
    closing_fragment: $ => seq('</', '>'),
    self_closing_fragment: $ => seq('<', '/>'),

    _child: $ => choice(
      $.element_expression,
      $.fragment,
      $.expression_child,
      $.text_child
    ),

    expression_child: $ => seq(
      '{',
      optional($.expression),
      '}'
    ),

    _expression_container: $ => seq(
      '{',
      $.expression,
      '}'
    ),

    text_child: $ => prec(-1, /[^<>{}\r\n]+/),

    // =========================================================================
    // Tokens & Literals
    // =========================================================================
    nil: $ => 'nil',
    boolean: $ => choice('true', 'false'),
    number: $ => {
      const decimal_digits = /[0-9]+/;
      const signed_integer = seq(optional(choice('-', '+')), decimal_digits);
      const decimal_exponent_part = seq(choice('e', 'E'), signed_integer);
      const decimal_literal = choice(
        seq(decimal_digits, optional(seq('.', optional(decimal_digits))), optional(decimal_exponent_part)),
        seq('.', decimal_digits, optional(decimal_exponent_part))
      );

      const hex_digits = /[0-9a-fA-F]+/;
      const hex_exponent_part = seq(choice('p', 'P'), signed_integer);
      const hex_literal = seq(
        choice('0x', '0X'),
        hex_digits,
        optional(seq('.', optional(hex_digits))),
        optional(hex_exponent_part)
      );

      return token(choice(decimal_literal, hex_literal));
    },

    string: $ => choice(
      seq(
        '"',
        repeat(choice(/[^"\\\n\r]+/, /\\./)),
        '"'
      ),
      seq(
        "'",
        repeat(choice(/[^'\\\n\r]+/, /\\./)),
        "'"
      ),
      $.multiline_string
    ),

    multiline_string: $ => {
      return choice(
        seq('[[', repeat(choice(/[^\]]+/, /\][^\]]/)), ']]'),
        seq('[=[', repeat(choice(/[^\]]+/, /\][^=]/, /\]=[^\]]/)), ']=]'),
        seq('[==[', repeat(choice(/[^\]]+/, /\][^=]/, /\]=[^=]/, /\]==[^\]]/)), ']==]')
      );
    },

    identifier: $ => /[a-zA-Z_][a-zA-Z0-9_]*/,

    comment: $ => choice(
      seq('--', /[^\r\n]*/),
      seq('--[[', repeat(choice(/[^\]]+/, /\][^\]]/)), ']]'),
      seq('--[=[', repeat(choice(/[^\]]+/, /\][^=]/, /\]=[^\]]/)), ']=]')
    ),

    jsx_comment: $ => seq(
      '{--',
      repeat(choice(/[^-]+/, /-[^-]/, /--[^}]/)),
      '--}'
    ),
  }
});
