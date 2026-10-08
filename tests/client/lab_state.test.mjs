import test from 'node:test';
import assert from 'node:assert/strict';
import {createStoryStore, restoreStoryArgs} from '../../lab/src/hydronium_lab/client/workbench.js';
test('story store shares confirmed args/playback, isolates snapshots and unsubscribes', async () => {
  const messages = []; let state = {args:{label:'A'},playback:{nowMs:0,frame:0,playing:true,intervalMs:10}};
  const store = createStoryStore({send:async message=>{
    messages.push(message);
    if(message.op==='args')state.args={...state.args,...message.args};
    if(message.op==='playback')state.playback={...state.playback,...Object.fromEntries(Object.entries(message).filter(([key])=>key!=='op'))};
    if(message.op==='advance')state.playback={...state.playback,nowMs:state.playback.nowMs+state.playback.intervalMs,frame:state.playback.frame+1,playing:false};
    return {lab:structuredClone(state)};
  }});
  store.select({id:'demo',args:{label:'A'},controls:{label:{type:'text'}}});
  let notifications=0; const stop=store.subscribe(()=>notifications++);
  await store.setArgs({label:'B'}); await store.pause(); await store.setInterval(20); await store.advance();
  assert.equal(store.getSnapshot().args.label,'B');
  assert.deepEqual(store.getSnapshot().playback,{nowMs:20,frame:1,playing:false,intervalMs:20});
  const snapshot=store.getSnapshot();snapshot.args.label='leaked';assert.equal(store.getSnapshot().args.label,'B');
  stop();const count=notifications;await store.play();assert.equal(notifications,count);
  assert.deepEqual(messages.map(message=>message.op),['args','playback','playback','advance','playback']);
  store.destroy();
});

test('HMR carries compatible edits and drops values invalid under the new schema',()=>{
  const story={args:{label:'Default'},controls:{count:{type:'number',max:2},choice:{type:'select',options:[{label:'No',value:false}]}}};
  assert.deepEqual(restoreStoryArgs(story,{label:'Edited',count:9,choice:false,removed:'old'}),{label:'Edited',choice:false});
});

test("stableJSON ignores key order, so a re-sent unchanged story is not a change", async () => {
  const { stableJSON } = await import("../../lab/src/hydronium_lab/client/workbench.js");
  // Release builds answer each catalog poll from a fresh Lua state, whose
  // table iteration order (and so the JSON key order) differs per request.
  const a = { title: { type: "text", label: "Title" }, accent: { type: "select", options: ["cyan", "green"] } };
  const b = { accent: { options: ["cyan", "green"], type: "select" }, title: { label: "Title", type: "text" } };
  assert.notEqual(JSON.stringify(a), JSON.stringify(b));
  assert.equal(stableJSON(a), stableJSON(b));
  assert.notEqual(stableJSON(a), stableJSON({ ...b, accent: { options: ["green", "cyan"], type: "select" } }), "array order still matters");
});
