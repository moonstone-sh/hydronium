// Fresh installed artifacts, generated SSR template, Bun dev supervision and Tailwind.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {join} from 'node:path';
import * as playwright from 'playwright';
// HYDRONIUM_BROWSER=firefox|webkit runs the same gate in another engine.
const chromium=playwright[process.env.HYDRONIUM_BROWSER||'chromium'];
const baseUrl=process.env.HYDRONIUM_CONSUMER_URL;
test('packaged SSR hydrates, preserves state through LUAX HMR, and updates Tailwind',{skip:!baseUrl},async t=>{
  const file=join(process.env.HYDRONIUM_CONSUMER_APP,'src/views/Counter.luax');
  const original=readFileSync(file,'utf8');
  const browser=await chromium.launch();
  const page=await browser.newPage();
  const errors=[];
  page.on('pageerror',e=>errors.push(String(e)));
  page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});
  const requested=[];
  page.on('request',r=>requested.push(new URL(r.url()).pathname));
  t.after(async()=>{writeFileSync(file,original);await browser.close();});
  const hmrReady=page.waitForRequest(r=>new URL(r.url()).pathname==='/__hydronium/watch',{timeout:30000});
  await page.goto(baseUrl,{waitUntil:'domcontentloaded'});
  await hmrReady;
  await page.locator('.count-display').waitFor();
  await page.waitForFunction(()=>document.querySelector('.count-display')?.textContent==='Count: 0');
  const boot=await page.evaluate(()=>performance.timeOrigin);
  await page.getByRole('button',{name:'+',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.count-display')?.textContent==='Count: 1');
  writeFileSync(file,original.replace('class="count-display"','class="count-display text-blue-500"').replace('count() + 1','count() + 2'));
  await page.waitForFunction(()=>document.querySelector('.count-display')?.classList.contains('text-blue-500'),null,{timeout:30000});
  assert.equal(await page.locator('.count-display').textContent(),'Count: 1','HMR preserves signal state');
  await page.getByRole('button',{name:'+',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.count-display')?.textContent==='Count: 3');
  await page.waitForFunction(()=>{const el=document.querySelector('.count-display');const probe=document.createElement('span');probe.className='text-blue-500';document.body.append(probe);const expected=getComputedStyle(probe).color;probe.remove();return expected!=='rgb(0, 0, 0)'&&getComputedStyle(el).color===expected;},null,{timeout:30000});
  assert.equal(await page.evaluate(()=>performance.timeOrigin),boot,'Lua and CSS updates must not reload the page');
  assert.deepEqual(errors,[],'no hydration or browser errors');
  // The dev page boots the default engine: this is LUAX HMR on lua-wasm.
  assert.ok(requested.some(p=>p.endsWith('/vendor/lua-wasm/5.4.9/engine.wasm')),'HMR must run on the default lua-wasm engine');
  assert.ok(!requested.some(p=>p.includes('wasmoon')),'the dev page must not boot Wasmoon');
});
