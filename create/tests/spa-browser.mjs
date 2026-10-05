// Build a generated SPA first, then run with HYDRONIUM_SPA_DIST pointing to dist/.
// PLAYWRIGHT_MODULE can point to a installed Playwright module when using a shared workspace.
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
import { join } from 'node:path';
import assert from 'node:assert/strict';
const root=process.env.HYDRONIUM_SPA_DIST;
assert.ok(root,'Set HYDRONIUM_SPA_DIST to a generated, Ballad/Vite-built SPA dist directory');
const server=Bun.serve({hostname:'127.0.0.1',port:0,async fetch(request){
 const path=new URL(request.url).pathname;
 const file=Bun.file(join(root,path==='/'?'index.html':path));
 if(!await file.exists()) return new Response('Not found',{status:404});
 return new Response(file,{headers:{'Content-Type':path.endsWith('.lua')?'text/plain':file.type}});
}});
const browser=await chromium.launch();
const page=await browser.newPage();const errors=[],failed=[];page.on('console',message=>{if(message.type()==='error')errors.push(message.text());});
page.on('pageerror',e=>errors.push(String(e)));
page.on('response',r=>{if(r.status()>=400) failed.push(r.url()+': '+r.status());});
try {
 await page.goto(server.url.href);
 await page.getByRole('button',{name:'More',exact:true}).waitFor({timeout:10000});
 assert.equal(await page.locator('.count').textContent(),'3');
 await page.getByRole('button',{name:'More',exact:true}).click();
 await page.waitForFunction(()=>document.querySelector('.count')?.textContent==='4');
 await page.fill('#name','Ada');await page.getByRole('button',{name:'Say hello',exact:true}).click();
 await page.waitForFunction(()=>document.querySelector('.result')?.textContent.includes('Hello, Ada!'));
 assert.equal(await page.locator('.result').textContent(),'Hello, Ada! Hello, Ada! Hello, Ada! Hello, Ada!');
 await page.getByRole('link',{name:'About',exact:true}).click();
 await page.waitForURL('**/#/about');assert.equal(await page.locator('h1').textContent(),'About');
 assert.equal(await page.locator('nav a[aria-current="page"]').textContent(),'About');
 await page.getByRole('link',{name:'Home',exact:true}).click();await page.waitForURL('**/#/');
 if(process.env.HYDRONIUM_SPA_FONT) await page.evaluate(async(name)=>{await document.fonts.load('12px '+name);},process.env.HYDRONIUM_SPA_FONT);
 assert.deepEqual(errors,[]);assert.deepEqual(failed,[]);
 console.log('SPA generated bundle: reactive Lua, greeting, hash navigation, starter.js and font fetch passed');
}catch(error){console.log({errors,failed,mount:await page.evaluate(()=>window.__hydroniumMountError),body:await page.locator('body').textContent()});throw error;}finally{await browser.close();server.stop(true);}
