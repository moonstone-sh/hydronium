const DONE=0,YIELDED=1,NIL=0,BOOLEAN=1,NUMBER=2,STRING=3,FUNCTION=5,HOST_REF=6,TABLE=7;
// Lua tables deeper than this are refused rather than risking the JS stack.
const MAX_TABLE_DEPTH=200;
const hasOwn=(object,key)=>Object.prototype.hasOwnProperty.call(object,key);
// Host-reference metamethods: JS objects reach Lua as userdata that index,
// assign, measure and iterate like the object they stand for.
const HOST_REF_METATABLE=`local mt = ...
local index, newindex, len, keys, text = __hydronium_ref_index, __hydronium_ref_newindex, __hydronium_ref_len, __hydronium_ref_keys, __hydronium_ref_tostring
__hydronium_ref_index, __hydronium_ref_newindex, __hydronium_ref_len, __hydronium_ref_keys, __hydronium_ref_tostring = nil, nil, nil, nil, nil
mt.__index = index
mt.__newindex = newindex
mt.__len = len
mt.__tostring = text
mt.__pairs = function(self)
  local list, i = keys(self), 0
  return function()
    i = i + 1
    local key = list[i]
    if key ~= nil then return key, self[key] end
  end, self, nil
end
`;

export class LuaTaskCancelledError extends Error {
  constructor(reason="Lua task cancelled") { super(reason instanceof Error?reason.message:String(reason)); this.name="LuaTaskCancelledError"; this.code="HYDRONIUM_TASK_CANCELLED"; }
}
const cancelled=(signal)=>new LuaTaskCancelledError(signal.reason??"Lua task cancelled");

function encode(module,value,callback) {
  const bytes=new TextEncoder().encode(String(value)), pointer=module._malloc(bytes.length+1);
  if (!pointer) throw new Error("Wasm string allocation failed");
  try { module.HEAPU8.set(bytes,pointer); module.HEAPU8[pointer+bytes.length]=0; return callback(pointer,bytes.length); }
  finally { module._free(pointer); }
}

class LuaTaskScope {
  #engine; #controller=new AbortController(); #tasks=new Set(); #closed=false;
  constructor(engine,metadata) { this.#engine=engine; this.metadata=Object.freeze({...metadata}); }
  run(source,options={}) {
    if (this.#closed) throw new Error("Lua task scope is closed");
    const controller=new AbortController(), external=options.signal;
    const forward=()=>controller.abort(this.#controller.signal.reason), forwardExternal=()=>controller.abort(external.reason);
    if (this.#controller.signal.aborted) forward(); else this.#controller.signal.addEventListener("abort",forward,{once:true});
    if (external?.aborted) forwardExternal(); else external?.addEventListener("abort",forwardExternal,{once:true});
    const result=this.#engine.run(source,{...options,signal:controller.signal}).finally(()=>{
      this.#controller.signal.removeEventListener("abort",forward); external?.removeEventListener("abort",forwardExternal); this.#tasks.delete(task);
    });
    const task=Object.freeze({result,cancel:(reason="Lua task cancelled")=>controller.abort(reason)});
    this.#tasks.add(task); return task;
  }
  async close(reason="Lua task scope closed") { if(this.#closed)return; this.#closed=true; this.#controller.abort(reason); await Promise.allSettled([...this.#tasks].map(t=>t.result)); }
}

export async function createTaskEngine({moduleFactory,moduleOptions={},bindings={}}={}) {
  if(typeof moduleFactory!=="function") throw new TypeError("moduleFactory is required");
  const module=await moduleFactory(moduleOptions);
  const required=["_hydronium_lua_create","_hydronium_lua_close","_hydronium_lua_version","_hydronium_task_set_host_start","_hydronium_task_set_host_invoke","_hydronium_task_set_host_ref_callbacks","_hydronium_task_set_host_function_release","_hydronium_task_create","_hydronium_task_create_function_call","_hydronium_task_resume","_hydronium_task_prepare_resume","_hydronium_task_thread","_hydronium_task_result_index","_hydronium_task_yield_id","_hydronium_task_release","_hydronium_task_push_boolean","_hydronium_state_push_nil","_hydronium_state_push_boolean","_hydronium_state_push_number","_hydronium_state_push_string","_hydronium_state_push_function_ref","_hydronium_state_push_host_ref","_hydronium_state_push_host_function","_hydronium_state_push_integer_text","_hydronium_state_push_error_message","_hydronium_state_top","_hydronium_state_settop","_hydronium_state_get_global","_hydronium_state_set_global","_hydronium_state_next","_hydronium_value_type_at","_hydronium_value_boolean_at","_hydronium_value_number_at","_hydronium_value_string_at","_hydronium_value_string_length_at","_hydronium_value_function_ref_at","_hydronium_value_host_ref_at","_hydronium_value_raw_length_at","_hydronium_value_is_integer_at","_hydronium_value_pointer_at","_hydronium_function_release","_hydronium_host_ref_install","_hydronium_global_set_host_function","_malloc","_free","addFunction","removeFunction"];
  for(const name of required) if(typeof module[name]!=="function") throw new Error(`task engine is missing ${name}`);
  if(!module.HEAPU8) throw new Error("task engine is missing HEAPU8");
  const state=module._hydronium_lua_create(); if(!state) throw new Error("Lua task state creation failed");
  const hostBindings=new Map(Object.entries(bindings)),hostOperations=new Map(),activeRuns=new Set(),liveFunctionReferences=new Set(),hostReferences=new Map(),hostReferenceIds=new WeakMap();
  let nextHostOperation=1,nextHostReference=1,nextHostFunction=1,activeContext,tail=Promise.resolve(),closed=false,engine,queued=0;
  const enqueue=(op)=>{queued++;const next=tail.then(op,op);tail=next.then(()=>{queued--;},()=>{queued--;});return next;};
  const decode=(pointer,length)=>pointer?new TextDecoder().decode(module.HEAPU8.subarray(pointer,pointer+length)):"";

  // Handles that are dropped without release() are released when collected,
  // so table results carrying functions do not leak registry slots.
  const releaseReference=(reference)=>{if(liveFunctionReferences.delete(reference)&&!closed)enqueue(()=>module._hydronium_function_release(state,reference));};
  const handleRegistry=typeof FinalizationRegistry==="function"?new FinalizationRegistry(releaseReference):null;
  class LuaFunctionHandle {
    #reference; #released=false;
    constructor(reference){this.#reference=reference;liveFunctionReferences.add(reference);handleRegistry?.register(this,reference,this);}
    get released(){return this.#released;}
    call(args=[],options={}){if(this.#released)return Promise.reject(new Error("Lua function handle is released"));if(!Array.isArray(args))throw new TypeError("Lua function arguments must be an array");return driveTask(()=>module._hydronium_task_create_function_call(state,this.#reference),args,options);}
    release(){if(this.#released)return;this.#released=true;handleRegistry?.unregister(this);releaseReference(this.#reference);}
    _referenceFor(target){if(target!==engine||this.#released)throw new Error("Lua function handle is released or belongs to another engine");return this.#reference;}
  }
  class HostReference {
    #id; #released=false;
    constructor(id){this.#id=id;}
    get value(){return this.#released?undefined:hostReferences.get(this.#id)?.value;}
    get released(){return this.#released;}
    release(){if(!this.#released){this.#released=true;const entry=hostReferences.get(this.#id);if(entry){entry.tokens--;collectHostReference(this.#id,entry);}}}
    _idFor(target){if(target!==engine||this.#released||!hostReferences.has(this.#id))throw new Error("host reference is released or belongs to another engine");return this.#id;}
  }
  function collectHostReference(id,entry){if(entry.tokens===0&&entry.luaRefs===0){hostReferences.delete(id);}}
  function makeHostReference(value){
    let id=hostReferenceIds.get(value),entry=id&&hostReferences.get(id);
    if(!entry){id=nextHostReference++;entry={value,tokens:0,luaRefs:0};hostReferenceIds.set(value,id);hostReferences.set(id,entry);}
    entry.tokens++;return new HostReference(id);
  }
  function retainHostReference(id){const entry=hostReferences.get(id);if(entry)entry.luaRefs++;}
  function releaseHostReference(id){const entry=hostReferences.get(id);if(entry){entry.luaRefs=Math.max(0,entry.luaRefs-1);collectHostReference(id,entry);}}
  function operationFor(callback){const name=`hydronium.callback.${nextHostFunction++}`;hostBindings.set(name,(args)=>callback(...args));return name;}
  const retainFunction=(reference)=>{if(!reference)throw new Error("failed to retain Lua function");return new LuaFunctionHandle(reference);};
  const absolute=(thread,index)=>index<0?module._hydronium_state_top(thread)+index+1:index;
  const hostValue=(id)=>{const entry=hostReferences.get(id);if(!entry)throw new Error("unknown or released host reference");return entry.value;};
  // One converter for every Lua -> JS crossing (results, globals, host
  // arguments, error values). Tables become arrays (keys exactly 1..n) or
  // plain objects; shared and cyclic subtables keep their identity.
  function readStackValue(thread,index,memo,depth=0){switch(module._hydronium_value_type_at(thread,index)){
    case NIL:return undefined;case BOOLEAN:return module._hydronium_value_boolean_at(thread,index)!==0;case NUMBER:return module._hydronium_value_number_at(thread,index);
    case STRING:return decode(module._hydronium_value_string_at(thread,index),module._hydronium_value_string_length_at(thread,index));
    case FUNCTION:return retainFunction(module._hydronium_value_function_ref_at(thread,index));
    case HOST_REF:return hostValue(module._hydronium_value_host_ref_at(thread,index));
    case TABLE:return readTable(thread,absolute(thread,index),memo??new Map(),depth);
    default:throw new TypeError("unsupported Lua value (userdata or thread) crossing to JavaScript");
  }}
  function tableKey(thread){switch(module._hydronium_value_type_at(thread,-2)){
    case STRING:return decode(module._hydronium_value_string_at(thread,-2),module._hydronium_value_string_length_at(thread,-2));
    case NUMBER:return String(module._hydronium_value_number_at(thread,-2));
    case BOOLEAN:return module._hydronium_value_boolean_at(thread,-2)!==0?"true":"false";
    default:throw new TypeError("unsupported Lua table key (table, function or userdata) crossing to JavaScript");
  }}
  function readTable(thread,index,memo,depth){
    const pointer=module._hydronium_value_pointer_at(thread,index);if(memo.has(pointer))return memo.get(pointer);
    if(depth>=MAX_TABLE_DEPTH)throw new TypeError(`Lua table nesting exceeds ${MAX_TABLE_DEPTH} levels`);
    const top=module._hydronium_state_top(thread),next=()=>{const step=module._hydronium_state_next(thread,index);if(step<0)throw new RangeError("Lua stack overflow while converting a table");return step===1;};
    try{
      const length=module._hydronium_value_raw_length_at(thread,index);let count=0,sequence=length>0;
      module._hydronium_state_push_nil(thread);
      while(next()){count++;if(sequence&&!(module._hydronium_value_type_at(thread,-2)===NUMBER&&module._hydronium_value_is_integer_at(thread,-2)&&module._hydronium_value_number_at(thread,-2)>=1&&module._hydronium_value_number_at(thread,-2)<=length))sequence=false;module._hydronium_state_settop(thread,-2);}
      const array=sequence&&count===length,result=array?new Array(length):{};memo.set(pointer,result);
      module._hydronium_state_push_nil(thread);
      while(next()){const value=readStackValue(thread,-1,memo,depth+1);
        if(array)result[module._hydronium_value_number_at(thread,-2)-1]=value;
        else{const key=tableKey(thread);if(key==="__proto__")Object.defineProperty(result,key,{value,enumerable:true,writable:true,configurable:true});else result[key]=value;}
        module._hydronium_state_settop(thread,-2);}
      return result;
    }finally{module._hydronium_state_settop(thread,top);}
  }
  function readValue(task){const index=module._hydronium_task_result_index(task);return index?readStackValue(module._hydronium_task_thread(task),index):undefined;}
  // The message native Lua would print for the error value (tostring(), so
  // __tostring applies); a table error value is also kept as `luaValue`.
  function readError(task){
    const thread=module._hydronium_task_thread(task),top=module._hydronium_state_top(state);let message;
    try{module._hydronium_state_push_error_message(state,thread,-1);message=readStackValue(state,-1);}finally{module._hydronium_state_settop(state,top);}
    const error=new Error(String(message??"Lua task failed"));
    if(module._hydronium_value_type_at(thread,-1)===TABLE){try{error.luaValue=readStackValue(thread,-1);}catch{}}
    return error;
  }
  const pushValue=(task,value)=>pushStateValue(module._hydronium_task_thread(task),value);
  function pushStateValue(state,value){
    if(value==null)module._hydronium_state_push_nil(state);else if(typeof value==="boolean")module._hydronium_state_push_boolean(state,value?1:0);else if(typeof value==="number")module._hydronium_state_push_number(state,value);
    else if(typeof value==="string")encode(module,value,(p,n)=>module._hydronium_state_push_string(state,p,n));
    else if(typeof value==="bigint"){if(!encode(module,value.toString(),(p)=>module._hydronium_state_push_integer_text(state,p)))throw new RangeError(`BigInt ${value} is outside Lua's 64-bit integer range`);}
    else if(value instanceof LuaFunctionHandle)module._hydronium_state_push_function_ref(state,value._referenceFor(engine));
    else if(value instanceof HostReference)module._hydronium_state_push_host_ref(state,value._idFor(engine));
    else if(typeof value==="function")encode(module,operationFor(value),(p)=>module._hydronium_state_push_host_function(state,p));
    else if(typeof value==="object"){
      const reference=makeHostReference(value);
      try{module._hydronium_state_push_host_ref(state,reference._idFor(engine));}finally{reference.release();}
    }else throw new TypeError(`unsupported JavaScript value: ${typeof value}`);
  }
  const hostFunction=module.addFunction((thread,namePointer,nameLength,firstIndex,argumentCount)=>{
    const id=nextHostOperation++,name=module.UTF8ToString(namePointer,nameLength),binding=hostBindings.get(name),context=activeContext;
    let args;try{args=Array.from({length:argumentCount},(_,offset)=>readStackValue(thread,firstIndex+offset));}catch(error){hostOperations.set(id,{run:()=>{throw error;}});return id;}
    // hydronium_task.start() begins the operation now (on a microtask, never
    // inside the Lua stack) so several started operations overlap; await
    // only collects the result. Plain host calls take the direct path above.
    const promise=Promise.resolve().then(()=>{if(!binding)throw new Error(`unknown host operation: ${name}`);if(!context)throw new Error("host operation started outside a scheduled Lua resume");if(context.signal.aborted)throw cancelled(context.signal);return binding(args,{signal:context.signal,owner:context.owner,generation:context.generation});});
    promise.catch(()=>{});hostOperations.set(id,{run:()=>promise});return id;
  },"iiiiii");
  // Direct host calls: run the binding now, inside the Lua call, and answer
  // plain values on the Lua stack. A promise becomes a pending operation the
  // coroutine yields on; a thrown error becomes a Lua error. JS exceptions
  // never cross the WebAssembly frames.
  const hostInvoke=module.addFunction((thread,namePointer,nameLength,firstIndex,argumentCount)=>{
    const name=module.UTF8ToString(namePointer,nameLength),binding=hostBindings.get(name),context=activeContext;let value;
    try{const args=Array.from({length:argumentCount},(_,offset)=>readStackValue(thread,firstIndex+offset));
      if(!binding)throw new Error(`unknown host operation: ${name}`);if(!context)throw new Error("host operation started outside a scheduled Lua resume");if(context.signal.aborted)throw cancelled(context.signal);
      value=binding(args,{signal:context.signal,owner:context.owner,generation:context.generation});
    }catch(error){pushStateValue(thread,String(error?.message??error));return -1;}
    if(!binding.direct&&value&&typeof value.then==="function"){value.catch?.(()=>{});const id=nextHostOperation++;hostOperations.set(id,{run:()=>value});return -(id+1);}
    try{pushStateValue(thread,value);return 1;}catch(error){pushStateValue(thread,String(error?.message??error));return -1;}
  },"iiiiii");
  const hostRefRetainFunction=module.addFunction((id)=>retainHostReference(id),"vi");
  const hostRefReleaseFunction=module.addFunction((id)=>releaseHostReference(id),"vi");
  const hostFunctionReleaseFunction=module.addFunction((pointer,length)=>hostBindings.delete(decode(pointer,length)),"vii");
  module._hydronium_task_set_host_start(hostFunction);
  module._hydronium_task_set_host_invoke(hostInvoke);
  module._hydronium_task_set_host_ref_callbacks(hostRefRetainFunction,hostRefReleaseFunction);
  module._hydronium_task_set_host_function_release(hostFunctionReleaseFunction);
  // Host-reference metamethods. Arrays index from 1 as Lua sequences do; a
  // method fetched from an object is bound to it and drops a leading self,
  // so both obj.method(x) and obj:method(x) work. Object.prototype members
  // read as nil unless the object defines them itself.
  const direct=(callback)=>{const name=operationFor(callback);hostBindings.get(name).direct=true;return name;};
  const refKey=(target,key)=>Array.isArray(target)&&typeof key==="number"?(Number.isInteger(key)&&key>=1?key-1:undefined):key;
  const refIndex=(target,key)=>{
    if(target==null||(typeof target!=="object"&&typeof target!=="function"))return undefined;
    const property=refKey(target,key);if(property===undefined)return undefined;
    if(!hasOwn(target,property)&&hasOwn(Object.prototype,property))return undefined;
    const value=target[property];
    return typeof value==="function"?(...args)=>value.apply(target,args.length&&args[0]===target?args.slice(1):args):value;
  };
  const refNewIndex=(target,key,value)=>{const property=refKey(target,key);if(property===undefined)throw new RangeError(`cannot assign array index ${key}`);if(value===undefined&&!Array.isArray(target))delete target[property];else target[property]=value;};
  const refLength=(target)=>Array.isArray(target)?target.length:typeof target?.length==="number"?target.length:0;
  const refKeys=(target)=>Array.isArray(target)?target.map((_,i)=>i+1):Object.keys(target);
  const refText=(target)=>{try{return String(target);}catch{return Array.isArray(target)?"[array]":"[object]";}};
  for(const [name,callback] of [["__hydronium_ref_index",refIndex],["__hydronium_ref_newindex",refNewIndex],["__hydronium_ref_len",refLength],["__hydronium_ref_keys",refKeys],["__hydronium_ref_tostring",refText]])
    encode(module,name,(namePointer)=>encode(module,direct(callback),(operationPointer)=>module._hydronium_global_set_host_function(state,namePointer,operationPointer)));
  if(encode(module,HOST_REF_METATABLE,(p)=>module._hydronium_host_ref_install(state,p))!==0)throw new Error("host reference metatable installation failed");
  function raceCancellation(promise,signal){let rejectCancellation;const cancellation=new Promise((_,reject)=>{rejectCancellation=reject;});const onAbort=()=>rejectCancellation(cancelled(signal));if(signal.aborted)onAbort();else signal.addEventListener("abort",onAbort,{once:true});return Promise.race([promise,cancellation]).finally(()=>signal.removeEventListener("abort",onAbort));}
  function takeHostOperation(id){const operation=hostOperations.get(id);if(!operation)throw new Error(`Lua yielded unknown host operation ${id}`);hostOperations.delete(id);return operation;}
  async function waitForHost(id,signal){const operation=takeHostOperation(id);const promise=Promise.resolve().then(operation.run);promise.catch(()=>{});return raceCancellation(promise,signal);}

  async function driveTask(create,initialArgs,{signal:externalSignal,deadlineMs,owner,generation}={}){
    if(closed)throw new Error("Lua task engine is closed");
    const controller=new AbortController(),forward=()=>controller.abort(externalSignal.reason);if(externalSignal?.aborted)forward();else externalSignal?.addEventListener("abort",forward,{once:true});
    let timer;if(deadlineMs!=null){if(!Number.isFinite(deadlineMs)||deadlineMs<0)throw new TypeError("deadlineMs must be non-negative");timer=setTimeout(()=>controller.abort(`Lua task deadline exceeded after ${deadlineMs} ms`),deadlineMs);}
    const context={controller,signal:controller.signal,owner,generation};activeRuns.add(context);let task,resume,first=true;
    const slice=()=>{activeContext=context;try{let count=0;if(first){for(const value of initialArgs)pushValue(task,value);count=initialArgs.length;first=false;}else if(resume){module._hydronium_task_prepare_resume(task);module._hydronium_task_push_boolean(task,resume.ok?1:0);pushValue(task,resume.value);count=2;}const status=module._hydronium_task_resume(task,count);if(status===DONE)return{status,value:readValue(task)};if(status===YIELDED)return{status,id:module._hydronium_task_yield_id(task)};return{status,error:readError(task)};}finally{activeContext=undefined;}};
    // Synchronous entry: with no Lua slice queued or running, the first slice -- and every host call that
    // returns a plain value -- runs in the caller's own stack (e.g. inside a DOM listener), so a Lua
    // preventDefault() lands before even a synthetic dispatchEvent() returns. The first host call that
    // returns a promise (or a busy engine) switches the task to the queued, asynchronous path.
    let synchronous=queued===0&&activeContext===undefined;
    try{task=synchronous?create():await enqueue(create);if(!task)throw new Error("Lua task creation failed");
      while(true){if(controller.signal.aborted)throw cancelled(controller.signal);const outcome=synchronous?slice():await enqueue(slice);
        if(outcome.status===DONE)return outcome.value;if(outcome.status!==YIELDED)throw outcome.error;
        if(synchronous){let value;try{value=takeHostOperation(outcome.id).run();}catch(error){resume={ok:false,value:error?.message??String(error)};continue;}
          if(!(value&&typeof value.then==="function")){resume={ok:true,value};continue;}
          synchronous=false;try{resume={ok:true,value:await raceCancellation(value,controller.signal)};}catch(error){if(controller.signal.aborted)throw cancelled(controller.signal);resume={ok:false,value:error?.message??String(error)};}continue;}
        try{resume={ok:true,value:await waitForHost(outcome.id,controller.signal)};}catch(error){if(controller.signal.aborted)throw cancelled(controller.signal);resume={ok:false,value:error?.message??String(error)};}}
    }finally{if(task)await enqueue(()=>module._hydronium_task_release(task));if(timer)clearTimeout(timer);externalSignal?.removeEventListener("abort",forward);activeRuns.delete(context);}
  }
  function withCString(value,callback){
    const text=String(value);if(text.includes("\0"))throw new TypeError("Lua global names and callback names must be NUL-free");
    return encode(module,text,(pointer)=>callback(pointer));
  }
  function setGlobal(name,value){
    if(closed)throw new Error("Lua task engine is closed");
    withCString(name,(namePointer)=>{const top=module._hydronium_state_top(state);try{pushStateValue(state,value);module._hydronium_state_set_global(state,namePointer);}finally{module._hydronium_state_settop(state,top);}});
  }
  function getGlobal(name){
    if(closed)throw new Error("Lua task engine is closed");
    return withCString(name,(namePointer)=>{const top=module._hydronium_state_top(state);try{module._hydronium_state_get_global(state,namePointer);return readStackValue(state,-1);}finally{module._hydronium_state_settop(state,top);}});
  }
  engine={api:2,module,
    bind(name,callback){if(closed)throw new Error("Lua task engine is closed");if(typeof name!=="string"||typeof callback!=="function")throw new TypeError("bind requires a name and function");hostBindings.set(name,callback);return()=>hostBindings.delete(name);},
    hostRef(value){if(closed)throw new Error("Lua task engine is closed");if((typeof value!=="object"&&typeof value!=="function")||value===null)throw new TypeError("hostRef requires an object or function");return makeHostReference(value);},
    global:Object.freeze({set:setGlobal,get:getGlobal}),
    doString(source){return engine.run(source);},
    version(){return module.UTF8ToString(module._hydronium_lua_version());},
    scope(metadata={}){if(closed)throw new Error("Lua task engine is closed");return new LuaTaskScope(engine,metadata);},
    run(source,{chunkName="=(hydronium-task)",...options}={}){if(typeof source!=="string"||source.includes("\0")||typeof chunkName!=="string"||chunkName.includes("\0"))throw new TypeError("task source and chunk name must be NUL-free strings");return driveTask(()=>encode(module,source,p=>encode(module,chunkName,c=>module._hydronium_task_create(state,p,c))),[],options);},
    async close(){if(closed)return;closed=true;for(const context of activeRuns)context.controller.abort("Lua task engine closed");while(activeRuns.size)await new Promise(resolve=>setTimeout(resolve,0));await enqueue(()=>{for(const reference of liveFunctionReferences)module._hydronium_function_release(state,reference);liveFunctionReferences.clear();module._hydronium_task_set_host_start(0);module._hydronium_task_set_host_invoke(0);module._hydronium_lua_close(state);module._hydronium_task_set_host_ref_callbacks(0,0);module._hydronium_task_set_host_function_release(0);module.removeFunction(hostFunction);module.removeFunction(hostInvoke);module.removeFunction(hostRefRetainFunction);module.removeFunction(hostRefReleaseFunction);module.removeFunction(hostFunctionReleaseFunction);});hostBindings.clear();hostOperations.clear();hostReferences.clear();}
  };
  return engine;
}
