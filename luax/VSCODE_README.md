# Hydronium LUAX for VS Code and VSCodium

Editor support for [Hydronium](https://github.com/moonstone-sh/hydronium)'s
`.luax` files (Lua with JSX-like tags) and its Markdown component modules
(`.mdx`).

- **Highlighting** for `.luax`, including dotted tags (`<d.button>`,
  `<UI.Card>`) and embedded Lua.
- **Completion, hover, go to definition and diagnostics** from
  `lua-language-server` with Hydronium's LuaLS plugin: `<d.` completes every
  DOM tag, attributes are typed (`disabled` is a boolean, `onSubmit`
  receives the form's values), and components get their own props checked.
- **Tags:** typing `>` closes the element, editing an opening tag's name
  renames its closing tag (linked editing), and *LUAX: Rename Tag*,
  *Remove Tag* and *Unwrap Tag* work on the tag at the cursor. Emmet
  abbreviations expand to LUAX tags.
- **Format Document:** `.luax` with Hydronium's LUAX formatter (bundled, no
  Lua install needed); `.lua` with lua-language-server's formatter.
- **Snippets** for typed components.

## Requirements

`lua-language-server`. The extension uses the one bundled with the
[Lua extension](https://open-vsx.org/extension/sumneko/lua) (`sumneko.lua`),
then `PATH`; or set `hydroniumLuax.server.path`.

Projects made with `hydronium create` already carry a `.luarc.json` pointing
at the plugin and types from their installed packages, and that file always
wins. Folders without one get the plugin and type libraries bundled with
this extension.

## Settings

| Setting | Default | |
|---|---|---|
| `hydroniumLuax.server.path` | `""` | Path to `lua-language-server`. |
| `hydroniumLuax.autoCloseTags` | `true` | Insert the closing tag on `>`. |
