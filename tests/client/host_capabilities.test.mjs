import test from 'node:test';
import assert from 'node:assert/strict';
import {installHostCapability} from '../../js/packages/dom-client/src/host_capabilities.js';
function engine(fail=false){const globals=new Map();const commands=[];return{globals,commands,global:{set:(k,v)=>globals.set(k,v)},doString:async code=>{commands.push(code);if(fail)throw new Error('VM failure');}};}
test('host installation uses versioned Lua registry, clears temporary transport, and optionally retains compatibility',async()=>{
 const lua=engine();const listener=()=>{};
 await installHostCapability(lua,{name:'dom',version:1,bindings:{set_listener:listener},legacyPrefix:'__dom_'});
 assert.match(lua.commands[0],/require\("hydronium.runtime.hosts"\).install\("dom", 1/);
 assert.equal(lua.globals.get('__dom_set_listener'),listener);
 assert.ok([...lua.globals].filter(([k])=>k.startsWith('__hydronium_host_transport_')).every(([,v])=>v===undefined));
 const isolated=engine();await installHostCapability(isolated,{name:'dom',version:1,bindings:{set_listener:listener}});
 assert.equal(isolated.globals.has('__dom_set_listener'),false);
});
test('failed installation releases transport slots and does not publish compatibility bindings',async()=>{
 const lua=engine(true);
 await assert.rejects(installHostCapability(lua,{name:'dom',version:1,bindings:{set_listener:()=>{}},legacyPrefix:'__dom_'}),/VM failure/);
 assert.equal(lua.globals.has('__dom_set_listener'),false);
 assert.ok([...lua.globals.values()].every(v=>v===undefined));
});
test('host transport rejects source injection and non-callable bindings before crossing into Lua',async()=>{
 const lua=engine();
 for(const args of [{name:'dom";error()',version:1,bindings:{}},{name:'dom',version:1,bindings:{'bad-name':()=>{}}},{name:'dom',version:1,bindings:{ping:1}}]){
  await assert.rejects(installHostCapability(lua,args),TypeError);
 }
 assert.equal(lua.globals.size,0);
});
