-- Locale belongs to a context, never to process-global state.
local M = {}
local function language(locale) return locale:match('^[^-_]+'):lower() end
local rtl = { ar = true, fa = true, he = true, ur = true, ps = true, dv = true }
function M.direction(locale) return rtl[language(locale)] and 'rtl' or 'ltr' end
function M.plural(locale, n, options)
  n = math.abs(assert(tonumber(n), 'plural requires a number'))
  assert(n == n and n ~= math.huge, 'plural requires a finite number')
  n = math.floor(n * 1000 + .5) / 1000
  local l, i = language(locale), math.floor(n)
  if options and options.type == 'ordinal' then
    if l == 'en' and n == i then
      local a, b = i % 10, i % 100
      if a == 1 and b ~= 11 then return 'one' end
      if a == 2 and b ~= 12 then return 'two' end
      if a == 3 and b ~= 13 then return 'few' end
    end
    if l == 'fr' and n == 1 then return 'one' end
    if l == 'it' and (n == 8 or n == 11 or n == 80 or n == 800) then return 'many' end
    return 'other'
  end
  if l == 'ja' or l == 'zh' or l == 'ko' or l == 'th' or l == 'vi' then return 'other' end
  if l == 'ar' then
    if n == 0 then return 'zero' elseif n == 1 then return 'one' elseif n == 2 then return 'two' end
    if n == i and n % 100 >= 3 and n % 100 <= 10 then return 'few' end
    if n == i and n % 100 >= 11 and n % 100 <= 99 then return 'many' end
    return 'other'
  end
  if l == 'ru' or l == 'uk' then
    if n ~= i then return 'other' end
    if i % 10 == 1 and i % 100 ~= 11 then return 'one' end
    if i % 10 >= 2 and i % 10 <= 4 and (i % 100 < 12 or i % 100 > 14) then return 'few' end
    return 'many'
  end
  if l == 'fr' or l == 'pt' then
    if (locale == 'pt-PT' and n == 1) or (locale ~= 'pt-PT' and i <= 1) then return 'one' end
    if n ~= 0 and n == i and i % 1000000 == 0 then return 'many' end
    return 'other'
  end
  if l == 'es' or l == 'it' then
    if n == 1 then return 'one' end
    if n ~= 0 and n == i and i % 1000000 == 0 then return 'many' end
    return 'other'
  end
  if l == 'en' or l == 'de' then return n == 1 and 'one' or 'other' end
  error('No native plural rule for ' .. locale .. '; provide a formatter adapter', 2)
end
local function grouped(digits, separator, width)
  local parts = {}
  while #digits > width do table.insert(parts, 1, digits:sub(-width)); digits = digits:sub(1, -width - 1) end
  table.insert(parts, 1, digits)
  return table.concat(parts, separator)
end
function M.number(value, spec)
  local n = assert(tonumber(value), 'number requires a number')
  assert(n == n and n ~= math.huge and n ~= -math.huge, 'number must be finite')
  if spec.style == 'percent' then n = n * 100 end
  local scale = 10 ^ spec.maximumFractionDigits
  local negative = n < 0 or (n == 0 and 1 / n < 0)
  local raw = string.format('%.' .. spec.maximumFractionDigits .. 'f', math.floor(math.abs(n) * scale + .5 + math.abs(n) * scale * 1e-15) / scale)
  local whole, fraction = raw:match('^(%d+)%.?(%d*)$')
  while #fraction > spec.minimumFractionDigits and fraction:sub(-1) == '0' do fraction = fraction:sub(1, -2) end
  if spec.useGrouping and math.abs(n) >= (spec.minGrouping or 1000) then whole = grouped(whole, spec.group, spec.groupWidth or 3) end
  local result = whole .. (#fraction > 0 and spec.decimal .. fraction or '')
  if spec.digits then result = result:gsub('%d', function(d) return spec.digits[tonumber(d) + 1] end) end
  return (negative and spec.negativePrefix or spec.prefix) .. result .. (negative and spec.negativeSuffix or spec.suffix)
end
-- UTC calendar conversion works in browser Lua without os.date/time.
local function civil(days)
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe/1460) + math.floor(doe/36524) - math.floor(doe/146096))/365)
  local y = yoe + era * 400
  local doy = doe - (365*yoe + math.floor(yoe/4) - math.floor(yoe/100))
  local mp = math.floor((5*doy+2)/153)
  local d = doy - math.floor((153*mp+2)/5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  return y + (m <= 2 and 1 or 0), m, d
end
function M.datetime(value, spec)
  local ms = assert(tonumber(value), 'datetime expects Unix milliseconds')
  assert(ms == ms and ms >= -62135596800000 and ms <= 253402300799999, 'datetime supports Gregorian years 1 through 9999')
  local sec = math.floor(ms / 1000)
  local y, m, d = civil(math.floor(sec / 86400))
  local values = { year = y, month = m, day = d, hour = math.floor(sec / 3600) % 24, minute = math.floor(sec / 60) % 60, second = sec % 60 }
  local out = {}
  for _, part in ipairs(spec.parts) do
    local value = values[part.type]
    if part.type == 'literal' then value = part.value
    elseif part.type == 'month' and spec.months then value = spec.months[m]
    elseif part.type == 'weekday' then value = spec.weekdays[(math.floor(sec / 86400) + 4) % 7 + 1]
    elseif part.type == 'dayPeriod' then value = values.hour < 12 and spec.am or spec.pm
    elseif value ~= nil then
      if part.type == 'year' and part.width == 2 then value = value % 100 end
      if part.type == 'hour' then
        if spec.hourCycle == 'h12' then value = (value - 1) % 12 + 1 elseif spec.hourCycle == 'h11' then value = value % 12 elseif spec.hourCycle == 'h24' then value = value == 0 and 24 or value end
      end
      value = part.width == 2 and string.format('%02d', value) or string.format('%d', value)
      if spec.digits then value = value:gsub('%d', function(n) return spec.digits[tonumber(n) + 1] end) end
    else error('Unsupported datetime part ' .. part.type, 2) end
    out[#out + 1] = tostring(value)
  end
  return table.concat(out)
end
function M.create(catalog, options)
  options = options or {}
  local known = {}; for _, locale in ipairs(catalog.locales) do known[locale] = true end
  local locale = options.locale or catalog.base_locale
  assert(known[locale], 'Unknown locale ' .. tostring(locale))
  local context = { locale = locale, direction = M.direction(locale), fallbacks = catalog.fallbacks, locales = catalog.locales, base_locale = catalog.base_locale }
  local formatters = options.formatters or {}
  function context:format(kind, value, opts, spec)
    if formatters[kind] then return formatters[kind](self.locale, value, opts) end
    if kind == 'plural' then return M.plural(self.locale, value, opts) end
    if kind == 'number' then return M.number(value, spec) end
    if kind == 'datetime' then return M.datetime(value, spec) end
    error('Unknown formatter ' .. tostring(kind), 2)
  end
  context.messages = {}
  for key, factory in pairs(catalog.catalogs[locale]) do context.messages[key] = function(params) return factory(params or {}, context) end end
  function context:href(path)
    assert(type(path) == 'string' and path:sub(1,1) == '/' and path:sub(1,2) ~= '//', 'Expected a site path')
    return self.locale == self.base_locale and path or '/' .. self.locale .. (path == '/' and '/' or path)
  end
  return context
end
function M.split(catalog, path)
  local first, rest = (path or '/'):match('^/([^/]+)(.*)$')
  for _, locale in ipairs(catalog.locales) do if first == locale then return locale, rest == '' and '/' or rest end end
  return catalog.base_locale, path or '/'
end
function M.detect(catalog, options)
  options = options or {}
  local first = (options.path or '/'):match('^/([^/]+)')
  local function resolve(value)
    if type(value) ~= 'string' then return end
    for _, locale in ipairs(catalog.locales) do if locale:lower() == value:lower() then return locale end end
    local base = value:match('^[^-_]+')
    for _, locale in ipairs(catalog.locales) do if locale == base then return locale end end
  end
  -- URL prefixes must match exactly; a preference never changes an explicit URL.
  for _, locale in ipairs(catalog.locales) do if first == locale then return locale end end
  local saved = resolve(options.preference); if saved then return saved end
  local candidates = {}
  for item in (options.accept_language or ''):gmatch('[^,]+') do
    local lang, quality = item:match('^%s*([%w%-]+)%s*;?%s*q?=?([%d%.]*)')
    if lang then candidates[#candidates+1] = { locale = lang, q = quality == '' and 1 or tonumber(quality) or 0, order = #candidates+1 } end
  end
  table.sort(candidates, function(a,b) if a.q ~= b.q then return a.q > b.q end return a.order < b.order end)
  for _, item in ipairs(candidates) do if item.q > 0 then local value = resolve(item.locale); if value then return value end end end
  return catalog.base_locale
end
return M
