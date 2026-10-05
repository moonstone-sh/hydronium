# Hydronium i18n

Compile one message catalog into Lua and JavaScript functions. Each render owns
its locale context, so concurrent requests and islands can use different
languages without changing global state.

From a Moonstone project in this workspace:

```sh
moon add path:../hydronium-templates/i18n
```

The package is under development; a registry release has not been published.
The workspace export now includes both the Lua runtime and `compiler/index.mjs`.
After installation from a candidate file registry, the compiler is available at
`.moonstone/env/libexec/hydronium/i18n/compiler/index.mjs`. A registry release will
use `moon add hydronium/i18n`; the path dependency above remains the local
source-development option.
Run the compiler with Bun from a build script:

```js
import { compileMessages } from '../hydronium-templates/i18n/compiler/index.mjs';

compileMessages({
  messagesDir: 'messages',
  outLua: 'src/messages.lua',
  outJs: 'src/messages.mjs',
  baseLocale: 'en',
});
```

This produces a Lua catalog with LuaLS message signatures, a JavaScript module,
and TypeScript declarations. Catalog keys and parameters must agree across
locales. Missing translations explicitly appear in `fallbacks`; unknown keys,
unsupported declarations, parameter mismatches, and incomplete variants fail
the build. Parameters used by any locale's formatter are typed as numbers in
all locales and checked at runtime. Other parameters accept strings or numbers.

```lua
local i18n = require('hydronium_i18n')
local catalog = require('messages')
local request = i18n.create(catalog, { locale = 'es' })
print(request.messages.hello({ name = 'Ada' }))
print(request:href('/docs')) -- /es/docs
print(request.direction) -- ltr
```

```js
import { createMessages } from './messages.mjs';
const t = createMessages('es');
console.log(t.hello({ name: 'Ada' }));
```

## Message format

Files are named `messages/en.json`, `messages/es.json`, and so on. The supported
[Inlang message format](https://github.com/opral/inlang/blob/main/packages/plugins/inlang-message-format/README.md)
subset includes string placeholders, input declarations, local `plural`,
`number`, and `datetime` formatters, and exact/select/wildcard conditions:

```json
{
  "$schema": "https://inlang.com/schema/inlang-message-format",
  "hello": "Hello {name}",
  "items": [{
    "declarations": ["input count", "local category = count: plural"],
    "selectors": ["category"],
    "match": {
      "category=one": "One item",
      "category=*": "{count} items"
    }
  }],
  "price": [{
    "declarations": ["input value", "local formatted = value: number style=currency currency=USD"],
    "match": { "formatted=*": "{formatted}" }
  }],
  "updated": [{
    "declarations": ["input timestamp", "local formatted = timestamp: datetime dateStyle=medium"],
    "match": { "formatted=*": "Updated {formatted}" }
  }]
}
```

A more specific condition precedes wildcard variants regardless of JSON order.
Use `*` for a general fallback; `other` is an exact plural category. Compound
selectors require a wildcard fallback. Message values are plain text; render
through your host's text APIs rather than inserting them as raw HTML.

## Locale and direction

`split(catalog, path)` returns the locale and its prefix-free path. The base
locale is unprefixed; an explicit `/en/` prefix is also recognized by the helper.
Your router must register any prefixed paths it intends to serve.

`detect(catalog, { path, preference, accept_language })` chooses an explicit URL
locale first, then a saved preference, then the highest accepted browser
language, finally the base locale. Resolve preferences only at entry and issue
an ordinary redirect; continue rendering the destination URL's locale on both
server and browser. Static exports need an entry script or hosting redirect
because they cannot inspect request headers. The Hydronium site demonstrates
an entry script in its document head and stores explicit language selections.

`direction(locale)` returns `rtl` for Arabic, Persian, Hebrew, Urdu, Pashto, and
Divehi. Put it on the document's `dir` attribute. Use logical CSS properties and
test the actual translated layout; direction metadata alone does not mirror an
application's custom controls.

## Native formatting boundaries

JavaScript uses `Intl`. The compiler derives number symbols and Gregorian date
patterns from the build environment's locale data for native/browser Lua.
Native formatting supports decimal, percent, and symbol/code currency styles,
uniform thousands grouping, and up to six fractional digits. Currency names,
compact/significant-digit notation, and nonuniform grouping require extending
the compiler/runtime together. Date inputs are Unix milliseconds, years 1–9999;
native dates use UTC and Gregorian calendars. Explicitly unsupported options
fail compilation, preventing an accidental server/browser mismatch.

Native cardinal/ordinal rules cover en, es, pt (including pt-PT), ja, de, fr,
it, ar, ru, uk, zh, ko, th, and vi. Plural operands follow the default Intl
three-fractional-digit precision. Context `formatters` adapters can replace
`plural`, `number`, or `datetime` for a host with its own locale services.

The standalone contract suite compares generated JS output with Lua and LuaJIT
and checks variant selection, invalid parameters, routing, and isolated locale
contexts:

```sh
bun i18n/tests/contracts.mjs
```

Run from the repository root with `lua` and `luajit` available. This establishes
parity for the fixtures; broader locale data, time-zone support and a Ballad
compiler node remain future extensions.
