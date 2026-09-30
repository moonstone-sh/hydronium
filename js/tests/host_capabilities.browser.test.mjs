import test from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {join,extname} from 'node:path';
import {chromium} from 'playwright';
const root=fileURLToPath(new URL('../../',import.meta.url));
const paths={
  'hydronium.runtime.hosts':'core/src/hydronium/runtime/hosts.lua',
  'hydronium_dom.host.dom':'dom/src/hydronium_dom/host/dom.lua',
  'hydronium_dom.host.contract':'dom/src/hydronium_dom/host/contract.lua',
  'hydronium_dom.host.legacy':'dom/src/hydronium_dom/host/legacy.lua',
  'hydronium_dom.style':'dom/src/hydronium_dom/style.lua',
};
const sources={};
for(const [id,path]of Object.entries(paths))sources[id]=await readFile(join(root,path),'utf8');
const fixture=`
local hosts = require("hydronium.runtime.hosts")
local contract = require("hydronium_dom.host.contract")
local bridge = hosts.require("dom", 1)
assert(_G.__dom_set_listener == nil, "test must work without legacy globals")
local names = {}
for _, method in ipairs(contract.manifest().methods) do names[#names + 1] = method.name end
table.sort(names)
assert(table.concat(names, ",") == __bridge_keys, "contract must match actual JS provider")
local host = require("hydronium_dom.host.dom").createDomHost()
local calls = 0
local first = { onClick = function() calls = calls + 1; bridge.set_attr(__button, "data-count", tostring(calls)) end }
__button = host.createInstance("button", first)
bridge.set_attr(__button, "data-count", "0")
bridge.append_child(__container, __button)
package.preload["capability.fixture"] = function() return {
  replace = function()
    local nextProps = { onClick = function() calls = calls + 2; bridge.set_attr(__button, "data-count", tostring(calls)) end }
    host.commitUpdate(__button, first, nextProps)
    first = nextProps
  end,
  remove = function() host.commitUpdate(__button, first, {}) end,
} end
assert(not pcall(hosts.require, "dom", 2))
assert(not pcall(hosts.install, "dom", 1, {}))
`;
const pageHtml=`<!doctype html><div id="a"></div><div id="b"></div><script type="module">
import {defaultBrowserEngineProvider} from '/engine_provider.js';
import {createDomBridge} from '/dom_bridge.js';
import {installHostCapability} from '/host_capabilities.js';
const sources=${JSON.stringify(sources)};
const fixture=${JSON.stringify(fixture)};
window.__engines=[];
for(const id of ['a','b']) {
 const lua=await defaultBrowserEngineProvider.create();
 for(const [name,source]of Object.entries(sources)) {
  lua.global.set('__preload_id',name);lua.global.set('__preload_src',source);
  await lua.doString('package.preload[__preload_id] = assert(load(__preload_src, "@" .. __preload_id))');
 }
 const bridge=createDomBridge();
 await installHostCapability(lua,{name:'dom',version:1,bindings:bridge});
 lua.global.set('__bridge_keys',Object.keys(bridge).sort().join(','));
 lua.global.set('__container',document.querySelector('#'+id));
 await lua.doString(fixture);
 window.__engines.push(lua);
}
window.__replace=()=>window.__engines[0].doString('require("capability.fixture").replace()');
window.__remove=()=>window.__engines[0].doString('require("capability.fixture").remove()');
window.__ready=true;
</script>`;
test('default Bridge API 2 Lua VMs resolve isolated DOM capabilities and replace/remove listeners',async t=>{
 const server=createServer(async(req,res)=>{
  const url=new URL(req.url,'http://localhost').pathname;
  if(url==='/'){res.writeHead(200,{'content-type':'text/html'}).end(pageHtml);return;}
  try{
   if(url.includes('..'))throw new Error('invalid path');
   const body=await readFile(join(root,'js/packages/dom-client/src',url.slice(1)));
   res.writeHead(200,{'content-type':['.js','.mjs'].includes(extname(url))?'text/javascript':extname(url)==='.wasm'?'application/wasm':'application/octet-stream'}).end(body);
  }catch{res.writeHead(404).end();}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const browser=await chromium.launch();
 t.after(async()=>{await browser.close();await new Promise(resolve=>server.close(resolve));});
 const page=await browser.newPage();const errors=[];
 page.on('pageerror',e=>errors.push(String(e)));
 await page.goto('http://127.0.0.1:'+server.address().port);
 await page.waitForFunction(()=>window.__ready===true);
 const a=page.locator('#a button'),b=page.locator('#b button');
 await a.click();await page.waitForFunction(()=>document.querySelector('#a button').dataset.count==='1');
 assert.equal(await b.getAttribute('data-count'),'0','second VM is isolated');
 await page.evaluate(()=>window.__replace());
 await a.click();await page.waitForFunction(()=>document.querySelector('#a button').dataset.count==='3');
 await page.evaluate(()=>window.__remove());await a.click();
 assert.equal(await a.getAttribute('data-count'),'3','removed listener cannot fire');
 await b.click();await page.waitForFunction(()=>document.querySelector('#b button').dataset.count==='1');
 assert.deepEqual(errors,[]);
});
