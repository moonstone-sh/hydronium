import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {build,createServer} from 'vite';
import {luaStyles} from '../dist/lua-styles.js';

function fixture(){
 const root=mkdtempSync(join(tmpdir(),'hydronium-lua-css-'));
 mkdirSync(join(root,'src'));
 writeFileSync(join(root,'src/Card.lua'),'local css=require("hydronium_dom.css")\nlocal styles=css.import("src/Card.module.css")\nreturn styles\n-- css.import(\"missing-comment.css\")\nlocal example=\"css.import(\\\"missing-string.css\\\")\"');
 writeFileSync(join(root,'src/Card.module.css'),'.base { padding: 1rem }\n.card { composes: base; color: red }');
 return root;
}
test('Lua imports become real Vite CSS Modules entries with class exports',async()=>{
 const root=fixture();
 try{
  await build({root,configFile:false,logLevel:'silent',plugins:[luaStyles()],build:{outDir:'dist'}});
  const manifest=JSON.parse(readFileSync(join(root,'dist/.vite/manifest.json'),'utf8'));
  const entry=manifest['src/Card.module.css'];
  assert.ok(entry.css?.length || entry.file.endsWith('.css')); 
  assert.equal(entry.classes.card.split(' ').length,2,'composition was lost');
  const css=readFileSync(join(root,'dist',entry.css?.[0] ?? entry.file),'utf8');
  for(const name of entry.classes.card.split(' '))assert.ok(css.includes('.'+name));
 }finally{rmSync(root,{recursive:true,force:true})}
});
test('declaration edits preserve class names and use CSS HMR; composition edits reload',async()=>{
 const root=fixture();let server;const plugin=luaStyles();
 try{
  server=await createServer({root,configFile:false,logLevel:'silent',plugins:[plugin],server:{middlewareMode:true,watch:null}});
  const path=join(root,'.hydronium/css-modules.json');
  const before=JSON.parse(readFileSync(path,'utf8'))['src/Card.module.css'];
  assert.ok(before.card);
  writeFileSync(join(root,'src/Card.module.css'),'.base { padding: 2rem }\n.card { composes: base; color: blue }');
  const messages=[];
  server.ws.send=message=>messages.push(message);
  const module=await server.moduleGraph.getModuleByUrl('/src/Card.module.css');
  const updated=await plugin.handleHotUpdate({file:join(root,'src/Card.module.css'),server,modules:[module]});
  assert.deepEqual(messages,[]);
  assert.deepEqual(updated,[],"prewarmed orphan JS must not force a reload");
  const after=JSON.parse(readFileSync(path,'utf8'))['src/Card.module.css'];
  assert.deepEqual(before,after);
  writeFileSync(join(root,'src/Card.module.css'),'.card { color: blue }');
  await plugin.handleHotUpdate({file:join(root,'src/Card.module.css'),server,modules:[module]});
  assert.deepEqual(messages,[{type:'full-reload'}]);
  assert.notEqual(before.card,JSON.parse(readFileSync(path,'utf8'))['src/Card.module.css'].card);
 }finally{await server?.close();rmSync(root,{recursive:true,force:true})}
});
