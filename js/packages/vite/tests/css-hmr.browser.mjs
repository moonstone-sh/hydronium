// Run explicitly: bun tests/css-hmr.browser.mjs (requires installed Chromium).
import assert from 'node:assert/strict';
import {mkdtempSync,mkdirSync,writeFileSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer} from 'vite';
import {chromium} from '../../../node_modules/playwright/index.mjs';
import {luaStyles} from '../dist/lua-styles.js';
const root=mkdtempSync(join(tmpdir(),'hydronium-css-browser-'));
let server,browser;
try{
 mkdirSync(join(root,'src'));
 writeFileSync(join(root,'src/Card.lua'),'local css=require("hydronium_dom.css");return css.import("src/Card.module.css")');
 writeFileSync(join(root,'src/Card.module.css'),'.card { color: rgb(255, 0, 0) }');
 writeFileSync(join(root,'index.html'),'<!doctype html><html><head><link rel="stylesheet" href="/src/Card.module.css"></head><body><input aria-label="Draft"><div id="card">Preview</div><script>window.marker=1</script></body></html>');
 const plugin=luaStyles();
 server=await createServer({root,configFile:false,logLevel:'error',plugins:[plugin],server:{host:'127.0.0.1',port:0}});
 const names=JSON.parse(readFileSync(join(root,'.hydronium/css-modules.json'),'utf8'))['src/Card.module.css'];
 await server.listen();
 browser=await chromium.launch({headless:true});
 const page=await browser.newPage();let navigations=0;
 page.on('framenavigated',frame=>{if(frame===page.mainFrame())navigations++});
 await page.goto(`http://127.0.0.1:${server.httpServer.address().port}`);
 await page.evaluate(name=>{document.querySelector("#card").className=name},names.card);
 await page.waitForFunction(()=>getComputedStyle(document.querySelector('#card')).color==='rgb(255, 0, 0)');
 await page.waitForTimeout(500);
 await page.getByRole('textbox',{name:'Draft'}).fill('unsaved draft');
 await page.evaluate(()=>{window.marker=42});
 writeFileSync(join(root,'src/Card.module.css'),'.card { color: rgb(0, 0, 255) }');
 await page.waitForFunction(()=>getComputedStyle(document.querySelector('#card')).color==='rgb(0, 0, 255)',{},{timeout:10000});
 assert.equal(await page.getByRole('textbox',{name:'Draft'}).inputValue(),'unsaved draft');
 assert.equal(await page.evaluate(()=>window.marker),42);
 assert.equal(await page.evaluate(()=>document.activeElement?.getAttribute('aria-label')),'Draft');
 assert.equal(navigations,1);
 console.log('PASS: CSS Modules link HMR preserves document, draft and focus');
}finally{await browser?.close();await server?.close();rmSync(root,{recursive:true,force:true})}
