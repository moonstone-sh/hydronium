import { mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const identifier = /^[A-Za-z_][A-Za-z0-9_]*$/;
const placeholders = text => [...text.matchAll(/\{([A-Za-z_][A-Za-z0-9_]*)\}/g)].map(m => m[1]);
const luaString = value => '"' + String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/\t/g, '\\t').replace(/[\x00-\x08\x0b\x0c\x0e-\x1f]/g, c => '\\' + c.charCodeAt(0).toString().padStart(3, '0')) + '"';
const luaValue = value => value === null || value === undefined ? 'nil' : typeof value === 'string' ? luaString(value) : typeof value === 'number' || typeof value === 'boolean' ? String(value) : Array.isArray(value) ? '{' + value.map(luaValue).join(',') + '}' : '{' + Object.entries(value).map(([key,v]) => `[${luaString(key)}]=${luaValue(v)}`).join(',') + '}';
function options(raw) {
  const out = {};
  const tokens = raw.match(/\w+=(?:"[^"]*"|'[^']*'|[^\s]+)/g) ?? [];
  if (tokens.join(' ').replace(/\s+/g,' ') !== raw.trim().replace(/\s+/g,' ')) throw Error(`Invalid formatter options: ${raw}`);
  for (const token of tokens) {
    const [key, ...parts] = token.split('='); let value = parts.join('=');
    if (/^["']/.test(value)) value = value.slice(1,-1);
    out[key] = value === 'true' ? true : value === 'false' ? false : /^\d+$/.test(value) ? Number(value) : value;
  }
  return out;
}
function numberSpec(locale, opts) {
  const allowed = ['style','currency','currencyDisplay','useGrouping','minimumFractionDigits','maximumFractionDigits'];
  for (const key of Object.keys(opts)) if (!allowed.includes(key)) throw Error(`Unsupported number option ${key}`);
  if (opts.currencyDisplay === 'name') throw Error('currencyDisplay=name requires plural-aware currency names; use symbol or code');
  if (opts.style && !['decimal','currency','percent'].includes(opts.style)) throw Error('Unsupported number style');
  const f = new Intl.NumberFormat(locale, opts), resolved = f.resolvedOptions();
  if (resolved.maximumFractionDigits > 6) throw Error('Native number formatting supports at most six fractional digits');
  const parts = f.formatToParts(1234567.89);
  const affixes = n => { const p = f.formatToParts(n), first = p.findIndex(x => x.type === 'integer'), last = p.findLastIndex(x => ['integer','group','decimal','fraction'].includes(x.type)); return [p.slice(0,first).map(x=>x.value).join(''), p.slice(last+1).map(x=>x.value).join('')]; };
  const [prefix,suffix] = affixes(1234.5), [negativePrefix,negativeSuffix] = affixes(-1234.5);
  const integers = parts.filter(p => p.type === 'integer');
  const minGrouping = [1000,10000,100000,1000000].find(n=>f.formatToParts(n / (resolved.style==='percent'?100:1)).some(p=>p.type==='group')) ?? 1e99;
  const digits = Array.from({length:10},(_,n) => new Intl.NumberFormat(locale,{useGrouping:false}).format(n));
  if (integers.length > 2 && [...integers.at(-2).value].length !== [...integers.at(-1).value].length) throw Error(`Native grouping pattern for ${locale} needs an adapter`);
  return {style:resolved.style, minimumFractionDigits:resolved.minimumFractionDigits, maximumFractionDigits:resolved.maximumFractionDigits, useGrouping:Boolean(resolved.useGrouping), decimal:parts.find(p=>p.type==='decimal')?.value ?? '.', group:parts.find(p=>p.type==='group')?.value ?? ',', minGrouping, groupWidth:[...integers.at(-1).value].length, prefix,suffix,negativePrefix,negativeSuffix,digits};
}
function dateSpec(locale, opts) {
  if (opts.timeZone && opts.timeZone !== 'UTC') throw Error('Native datetime formatting currently requires UTC');
  const allowed = ['dateStyle','timeStyle','year','month','day','weekday','hour','minute','second','hour12','hourCycle','timeZone'];
  for (const key of Object.keys(opts)) if (!allowed.includes(key)) throw Error(`Unsupported datetime option ${key}`);
  const formatter = new Intl.DateTimeFormat(locale,{...Object.keys(opts).length ? opts : {dateStyle:'medium'},timeZone:'UTC'});
  const resolved = formatter.resolvedOptions();
  if (resolved.calendar !== 'gregory') throw Error(`Native calendar ${resolved.calendar} needs an adapter`);
  const sample = new Date('2026-11-23T17:08:09Z');
  const widthParts = formatter.formatToParts(new Date('2026-03-07T05:08:09Z'));
  const parts = formatter.formatToParts(sample).map(p=>({type:p.type,value:p.type==='literal'?(formatter.format(sample).includes('\u202f')?p.value:p.value.replace(/\u202f/g,' ')):undefined,width:/^\p{N}{2}$/u.test(widthParts.find(x=>x.type===p.type)?.value ?? '')?2:undefined}));
  if (parts.some(p=>p.type==='timeZoneName')) throw Error('timeZoneName needs a formatter adapter');
  const months = Array.from({length:12},(_,m)=>formatter.formatToParts(new Date(Date.UTC(2026,m,23,17,8,9))).find(p=>p.type==='month')?.value);
  const textual = months.some(m=>m && /[^\p{N}]/u.test(m));
  const weekdays = Array.from({length:7},(_,d)=>formatter.formatToParts(new Date(Date.UTC(2026,10,22+d,17,8,9))).find(p=>p.type==='weekday')?.value ?? '');
  return {parts, months:textual?months:undefined,weekdays,hourCycle:resolved.hourCycle,am:formatter.formatToParts(new Date('2026-11-23T05:08:09Z')).find(p=>p.type==='dayPeriod')?.value,pm:formatter.formatToParts(sample).find(p=>p.type==='dayPeriod')?.value,digits:Array.from({length:10},(_,n)=>new Intl.NumberFormat(locale,{useGrouping:false}).format(n))};
}
function normalize(value, locale, key) {
  if (typeof value === 'string') return { inputs:[...new Set(placeholders(value))], types:{}, locals:[], variants:[{conditions:[],text:value}] };
  if (!Array.isArray(value) || value.length !== 1 || !value[0]?.match) throw Error(`${locale}.${key}: expected a string or one Inlang variant message`);
  const message=value[0], inputs=new Set(), explicitInputs=new Set(), locals=[], types={};
  const infer = name => { if(!identifier.test(name)) throw Error('Invalid input name'); inputs.add(name); };
  for(const selector of message.selectors ?? []) infer(selector);
  for(const match of Object.keys(message.match)) for(const part of match.split(',')) { const name=part.trim().split('=')[0]; infer(name); }
  for (const declaration of message.declarations ?? []) {
    const input=declaration.match(/^input (\w+)$/);
    if(input) { if(!identifier.test(input[1]) || explicitInputs.has(input[1]) || locals.some(x=>x.name===input[1])) throw Error('Invalid input name'); inputs.add(input[1]); explicitInputs.add(input[1]); continue; }
    const local=declaration.match(/^local (\w+) = (\w+): (plural|number|datetime)(.*)$/);
    if(!local) throw Error(`${locale}.${key}: unsupported declaration ${declaration}`);
    const [,name,from,kind,raw]=local; const opts=options(raw);
    inputs.delete(name);
    if(!identifier.test(name)||!identifier.test(from)||explicitInputs.has(name)||locals.some(x=>x.name===name)) throw Error('Invalid or duplicate local declaration');
    if(!inputs.has(from)&&!locals.some(x=>x.name===from)) infer(from);
    if(inputs.has(from)) types[from]='number';
    else throw Error(`${locale}.${key}: formatter inputs must be raw parameters`);
    if(kind==='plural'&&!['en','es','pt','ja','de','fr','it','ar','ru','uk','zh','ko','th','vi'].includes(locale.split('-')[0])) throw Error(`Native plural rules for ${locale} are not implemented`);
    if(kind==='plural'&&Object.keys(opts).some(k=>k!=='type')) throw Error('Unsupported plural option');
    if(kind==='plural'&&opts.type&&!['cardinal','ordinal'].includes(opts.type)) throw Error('Invalid plural type');
    locals.push({name,from,kind,options:opts,spec:kind==='number'?numberSpec(locale,opts):kind==='datetime'?dateSpec(locale,opts):undefined});
  }
  const known=new Set([...inputs,...locals.map(x=>x.name)]);
  const variants=Object.entries(message.match).map(([match,text])=>{
    if(typeof text!=='string') throw Error(`${locale}.${key}: variant must be text`);
    const conditions=match.split(',').map(part=>{const m=part.trim().match(/^(\w+)=(.+)$/);if(!m||!known.has(m[1])) throw Error(`Invalid selector ${part}`);return {name:m[1],value:m[2].trim()};});
    for(const name of placeholders(text)) if(!known.has(name)) inputs.add(name);
    return {conditions,text};
  });
  for (const selector of message.selectors ?? []) if (!known.has(selector)) throw Error(`Undeclared selector ${selector}`);
  const wildcard = variants.some(v=>v.conditions.every(c=>c.value==='*'));
  const exhaustivePlural = locals.some(l=>l.kind==='plural' && new Intl.PluralRules(locale,l.options).resolvedOptions().pluralCategories.every(category=>variants.some(v=>v.conditions.length===1 && v.conditions[0].name===l.name && v.conditions[0].value===category)));
  if(!wildcard && !exhaustivePlural) throw Error(`${locale}.${key}: a catch-all variant is required`);
  variants.sort((a,b)=>b.conditions.filter(c=>c.value!=='*').length-a.conditions.filter(c=>c.value!=='*').length);
  return {inputs:[...inputs].sort(),types,locals,variants};
}
function luaFunction(message) {
  const lines=['function(p,ctx)','local v = {}'];
  for(const input of message.inputs) lines.push(`assert(${message.types[input]==='number'?`type(p[${luaString(input)}]) == 'number' and p[${luaString(input)}] == p[${luaString(input)}] and math.abs(p[${luaString(input)}]) ~= math.huge`:`type(p[${luaString(input)}]) == 'string' or type(p[${luaString(input)}]) == 'number'`}, ${luaString('Invalid message parameter '+input)}); v[${luaString(input)}] = p[${luaString(input)}]`);
  for(const local of message.locals) lines.push(`v[${luaString(local.name)}] = ctx:format(${luaString(local.kind)}, v[${luaString(local.from)}], ${luaValue(local.options)}, ${luaValue(local.spec)})`);
  const text=raw=> { let end=0,parts=[]; for(const m of raw.matchAll(/\{(\w+)\}/g)){if(m.index>end)parts.push(luaString(raw.slice(end,m.index)));parts.push(`tostring(v[${luaString(m[1])}])`);end=m.index+m[0].length;}if(end<raw.length)parts.push(luaString(raw.slice(end)));return parts.join(' .. ')||'""';};
  for(const variant of message.variants) {const condition=variant.conditions.filter(c=>c.value!=='*').map(c=>`tostring(v[${luaString(c.name)}]) == ${luaString(c.value)}`).join(' and ')||'true';lines.push(`if ${condition} then return ${text(variant.text)} end`);}
  lines.push('error("No matching message variant")','end');return lines.join('\n');
}
export function compileMessages({messagesDir,outLua,outJs,baseLocale='en'}) {
  const locales=readdirSync(messagesDir).filter(f=>f.endsWith('.json')).map(f=>f.slice(0,-5)).sort();
  for(const locale of locales) if(Intl.getCanonicalLocales(locale)[0] !== locale) throw Error(`Locale filename must use canonical BCP 47 spelling: ${locale}`);
  if(!locales.includes(baseLocale))throw Error(`Missing base locale ${baseLocale}`);
  locales.splice(locales.indexOf(baseLocale),1);locales.unshift(baseLocale);
  const raw=Object.fromEntries(locales.map(l=>[l,JSON.parse(readFileSync(join(messagesDir,l+'.json'),'utf8'))]));
  const keys=Object.keys(raw[baseLocale]).filter(k=>k!=='$schema').sort(), catalogs={},fallbacks={};
  for(const key of keys)if(!identifier.test(key) || ['__proto__','constructor','prototype'].includes(key))throw Error(`Invalid key ${key}`);
  for(const locale of locales){catalogs[locale]={};for(const key of Object.keys(raw[locale]))if(key!=='$schema'&&!keys.includes(key))throw Error(`Unknown key ${locale}.${key}`);
    for(const key of keys){let value=raw[locale][key];if(value===undefined){(fallbacks[locale]??=[]).push(key);value=raw[baseLocale][key];}catalogs[locale][key]=normalize(value,locale,key);}
  }
  for(const locale of locales)for(const key of keys)if([...catalogs[locale][key].inputs].sort().join()!==[...catalogs[baseLocale][key].inputs].sort().join())throw Error(`Parameter mismatch ${locale}.${key}`);
  // A parameter used by any locale's formatter is numeric in every locale.
  for(const key of keys) for(const input of catalogs[baseLocale][key].inputs) {
    if(locales.some(l=>catalogs[l][key].types[input]==='number')) for(const l of locales) catalogs[l][key].types[input]='number';
  }
  let lua='-- Generated by hydronium/i18n. Do not edit.\n---@class i18n.Messages\n';
  for(const key of keys)lua+=`---@field ${key} fun(p${catalogs[baseLocale][key].inputs.length?'':'?'}: {${catalogs[baseLocale][key].inputs.map(n=>n+': '+(catalogs[baseLocale][key].types[n]||'string|number')).join(',')}}): string\n`;
  lua+=`local M = { base_locale=${luaString(baseLocale)}, locales=${luaValue(locales)}, fallbacks=${luaValue(fallbacks)}, catalogs={} }\n`;
  for(const locale of locales)lua+=`M.catalogs[${luaString(locale)}] = {\n${keys.map(k=>`[${luaString(k)}]=${luaFunction(catalogs[locale][k])}`).join(',\n')}\n}\n`;
  lua+='return M\n';mkdirSync(dirname(outLua),{recursive:true});writeFileSync(outLua,lua);
  const runtime=`const catalogs = ${JSON.stringify(catalogs)};\nexport const locales = ${JSON.stringify(locales)};\nexport const baseLocale = ${JSON.stringify(baseLocale)};\nexport const fallbacks = ${JSON.stringify(fallbacks)};\nexport function createMessages(locale = baseLocale) {\nif(!locales.includes(locale)) throw Error('Unknown locale '+locale);\nconst out={};\nfor(const [key,message] of Object.entries(catalogs[locale])) out[key]=(params={})=>{\nconst v={...params};for(const input of message.inputs) if(message.types[input]==='number'?!Number.isFinite(v[input]):!['string','number'].includes(typeof v[input]))throw Error('Invalid message parameter '+input);\nfor(const local of message.locals){const options=local.options;if(local.kind==='datetime' && (v[local.from]<-62135596800000 || v[local.from]>253402300799999)) throw Error('datetime supports Gregorian years 1 through 9999');v[local.name]=local.kind==='plural'?new Intl.PluralRules(locale,options).select(Number(v[local.from])):local.kind==='number'?new Intl.NumberFormat(locale,options).format(Number(v[local.from])):new Intl.DateTimeFormat(locale,{...(Object.keys(options).length?options:{dateStyle:'medium'}),timeZone:'UTC'}).format(Number(v[local.from]));}\nconst variant=message.variants.find(x=>x.conditions.every(c=>c.value==='*'||String(v[c.name])===c.value));if(!variant)throw Error('No matching variant '+key);\nreturn variant.text.replace(/\\{(\\w+)\\}/g,(_,name)=>String(v[name]));};return out;\n}\nexport function direction(locale) { return ['ar','fa','he','ur','ps','dv'].includes(locale.split('-')[0])?'rtl':'ltr'; }\n`;
  mkdirSync(dirname(outJs),{recursive:true});writeFileSync(outJs,runtime);
  writeFileSync(outJs.replace(/\.(mjs|js)$/,'.d.ts'),`export type Locale = ${locales.map(l=>JSON.stringify(l)).join(' | ')};\nexport interface Messages {\n${keys.map(k=>`  ${k}(params${catalogs[baseLocale][k].inputs.length?'':'?'}: {${catalogs[baseLocale][k].inputs.map(n=>`${n}: ${catalogs[baseLocale][k].types[n]||'string | number'}`).join(';')}}): string;`).join('\n')}\n}\nexport declare function createMessages(locale?: Locale): Messages;\nexport declare function direction(locale: Locale): 'ltr' | 'rtl';\nexport declare const locales: Locale[];\nexport declare const baseLocale: Locale;\nexport declare const fallbacks: Partial<Record<Locale,string[]>>;\n`);
  return {keys:keys.length,locales,fallbacks};
}
