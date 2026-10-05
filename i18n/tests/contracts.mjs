import { compileMessages } from '../compiler/index.mjs';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import assert from 'node:assert/strict';
const dir = mkdtempSync(join(tmpdir(), 'hydronium-i18n-'));
const messagesDir = join(dir, 'messages'); mkdirSync(messagesDir);
const variant = (kind, options='') => [{ declarations: ['input value', `local result = value: ${kind} ${options}`.trim()], match: { 'result=*': '{result}' } }];
const source = {
  greeting: 'Hello {name}',
  items: [{ declarations: ['input count', 'local category = count: plural'], match: { 'category=*': '{count} items', 'category=one': 'One item' } }],
  choose: [{match:{'role=admin':'Admin {name}', 'role=*':'User {name}'}}],
  number: variant('number'), percent: variant('number','style=percent'), currency: variant('number','style=currency currency=USD'),
  date: variant('datetime','dateStyle=full timeStyle=medium'), short_date: variant('datetime','year=2-digit month=2-digit day=2-digit'),
  ordinal: variant('plural','type=ordinal'), plural: variant('plural'),
};
for (const locale of ['en','es','pt','pt-PT','ja','ar','fr','it','ru']) writeFileSync(join(messagesDir,locale+'.json'),JSON.stringify(source));
const outLua=join(dir,'catalog.lua'), outJs=join(dir,'messages.mjs');
compileMessages({messagesDir,outLua,outJs});
const generated=await import(pathToFileURL(outJs));
const root=resolve(import.meta.dirname,'..');
const cases=[];
for(const locale of generated.locales) {
  const t=generated.createMessages(locale);
  assert.equal(t.items({count:1}),new Intl.PluralRules(locale).select(1)==='one'?'One item':'1 items'); // specific conditions outrank an earlier wildcard
  assert.equal(t.choose({role:'admin',name:'Ada'}),'Admin Ada');
  assert.throws(()=>t.greeting({name:{}}),/Invalid message parameter/);
  assert.throws(()=>t.number({value:'4'}),/Invalid message parameter/);
  for (const value of [-1234567.895,-1000,-1,-0,0,1,1.0001,1.005,1.234,2,3,3.5,8,11,21,80,800,1000,10000,1000000,1234567.895]) {
    for(const key of ['number','currency','percent','plural','ordinal']) cases.push({locale,key,value,want:t[key]({value})});
  }
  for(const value of [0,Date.UTC(2000,1,29,0,8,9),Date.UTC(2026,10,23,17,8,9),Date.UTC(2025,11,31,23,59,59)]) {
    for(const key of ['date','short_date']) cases.push({locale,key,value,want:t[key]({value})});
  }
}
const ls=x=>'"'+x.replace(/\\/g,'\\\\').replace(/"/g,'\\"').replace(/\n/g,'\\n')+'"';
writeFileSync(join(dir,'check.lua'),`
package.path = ${ls(root+'/src/?.lua;'+root+'/src/?/init.lua;')} .. package.path
local runtime = require('hydronium_i18n')
local catalog = dofile(${ls(outLua)})
local contexts = {}
${generated.locales.map(l=>`contexts[${ls(l)}] = runtime.create(catalog,{locale=${ls(l)}})`).join('\n')}
${cases.map(c=>`assert(contexts[${ls(c.locale)}].messages.${c.key}({value=${Object.is(c.value,-0)?'-0.0':c.value}}) == ${ls(c.want)}, ${ls(`${c.locale}.${c.key}(${c.value}): expected ${c.want}`)})`).join('\n')}
assert(contexts.en.messages.greeting({name='Ada'}) == 'Hello Ada')
assert(contexts.es.locale == 'es' and contexts.en.locale == 'en')
assert(contexts.ar.direction == 'rtl')
assert(contexts.es:href('/docs') == '/es/docs')
assert(runtime.detect(catalog,{path='/ja/docs',preference='es'}) == 'ja')
assert(runtime.detect(catalog,{path='/en/',preference='es'}) == 'en')
assert(runtime.detect(catalog,{path='/',preference='pt-BR'}) == 'pt')
assert(runtime.detect(catalog,{accept_language='en;q=0,ja;q=0.4,es;q=0.9'}) == 'es')
assert(not pcall(contexts.en.messages.number,{value='4'}))
print('Lua contracts passed')
`);
for(const executable of ['lua','luajit']) {
  process.stdout.write(execFileSync(executable,[join(dir,'check.lua')],{encoding:'utf8'}));
}
// Bad input must fail during compilation rather than survive into production.
writeFileSync(join(messagesDir,'es.json'),JSON.stringify({...source,greeting:'Hola {wrong}'}));
assert.throws(()=>compileMessages({messagesDir,outLua,outJs}),/Parameter mismatch/);
console.log(`${cases.length} Lua/JS formatter comparisons passed on Lua and LuaJIT`);
