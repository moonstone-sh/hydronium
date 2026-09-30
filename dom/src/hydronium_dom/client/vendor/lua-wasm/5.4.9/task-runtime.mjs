const DONE=0,YIELDED=1,NIL=0,BOOLEAN=1,NUMBER=2,STRING=3,FUNCTION=5,HOST_REF=6;

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
  const required=["_hydronium_lua_create","_hydronium_lua_close","_hydronium_task_set_host_start","_hydronium_task_set_host_ref_callbacks","_hydronium_task_set_host_function_release","_hydronium_task_create","_hydronium_task_create_function_call","_hydronium_task_resume","_hydronium_task_prepare_resume","_hydronium_task_push_nil","_hydronium_task_push_boolean","_hydronium_task_push_number","_hydronium_task_push_string","_hydronium_task_push_function_ref","_hydronium_task_push_host_ref","_hydronium_task_push_host_function","_hydronium_task_result_type","_hydronium_task_result_boolean","_hydronium_task_result_number","_hydronium_task_result_string","_hydronium_task_result_string_length","_hydronium_task_result_function_ref","_hydronium_task_result_host_ref","_hydronium_value_type_at","_hydronium_value_boolean_at","_hydronium_value_number_at","_hydronium_value_string_at","_hydronium_value_string_length_at","_hydronium_value_function_ref_at","_hydronium_value_host_ref_at","_hydronium_function_release","_hydronium_global_set_nil","_hydronium_global_set_boolean","_hydronium_global_set_number","_hydronium_global_set_string","_hydronium_global_set_function_ref","_hydronium_global_set_host_ref","_hydronium_global_set_host_function","_hydronium_global_get_type","_hydronium_global_get_boolean","_hydronium_global_get_number","_hydronium_global_get_string","_hydronium_global_get_string_length","_hydronium_global_get_function_ref","_hydronium_global_get_host_ref","_hydronium_task_yield_id","_hydronium_task_release","_malloc","_free","addFunction","removeFunction"];
  for(const name of required) if(typeof module[name]!=="function") throw new Error(`task engine is missing ${name}`);
  if(typeof module._hydronium_task_result_host_ref!=="function") throw new Error("task engine is missing _hydronium_task_result_host_ref");
  if(!module.HEAPU8) throw new Error("task engine is missing HEAPU8");
  const state=module._hydronium_lua_create(); if(!state) throw new Error("Lua task state creation failed");
  const hostBindings=new Map(Object.entries(bindings)),hostOperations=new Map(),activeRuns=new Set(),functionHandles=new Set(),hostReferences=new Map(),hostReferenceIds=new WeakMap();
  let nextHostOperation=1,nextHostReference=1,nextHostFunction=1,activeContext,tail=Promise.resolve(),closed=false,engine;
  const enqueue=(op)=>{const next=tail.then(op,op);tail=next.then(()=>undefined,()=>undefined);return next;};
  const decode=(pointer,length)=>pointer?new TextDecoder().decode(module.HEAPU8.subarray(pointer,pointer+length)):"";

  class LuaFunctionHandle {
    #reference; #released=false;
    constructor(reference){this.#reference=reference;functionHandles.add(this);}
    get released(){return this.#released;}
    call(args=[],options={}){if(this.#released)return Promise.reject(new Error("Lua function handle is released"));if(!Array.isArray(args))throw new TypeError("Lua function arguments must be an array");return driveTask(()=>module._hydronium_task_create_function_call(state,this.#reference),args,options);}
    release(){if(this.#released)return;this.#released=true;functionHandles.delete(this);if(!closed)enqueue(()=>module._hydronium_function_release(state,this.#reference));}
    _referenceFor(target){if(target!==engine||this.#released)throw new Error("Lua function handle is released or belongs to another engine");return this.#reference;}
    _close(){if(!this.#released){module._hydronium_function_release(state,this.#reference);this.#released=true;functionHandles.delete(this);}}
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
  function readStackValue(thread,index){switch(module._hydronium_value_type_at(thread,index)){
    case NIL:return undefined;case BOOLEAN:return module._hydronium_value_boolean_at(thread,index)!==0;case NUMBER:return module._hydronium_value_number_at(thread,index);
    case STRING:return decode(module._hydronium_value_string_at(thread,index),module._hydronium_value_string_length_at(thread,index));
    case FUNCTION:return retainFunction(module._hydronium_value_function_ref_at(thread,index));
    case HOST_REF:{const entry=hostReferences.get(module._hydronium_value_host_ref_at(thread,index));if(!entry)throw new Error("unknown or released host reference");return entry.value;}
    default:throw new TypeError(`unsupported Lua value at host argument ${index}`);
  }}
  function readValue(task){switch(module._hydronium_task_result_type(task)){
    case NIL:return undefined;case BOOLEAN:return module._hydronium_task_result_boolean(task)!==0;case NUMBER:return module._hydronium_task_result_number(task);
    case STRING:return decode(module._hydronium_task_result_string(task),module._hydronium_task_result_string_length(task));
    case FUNCTION:return retainFunction(module._hydronium_task_result_function_ref(task));
    case HOST_REF:{const entry=hostReferences.get(module._hydronium_task_result_host_ref(task));if(!entry)throw new Error("unknown or released host reference");return entry.value;}
    default:throw new TypeError("Lua task returned an unsupported value");
  }}
  function pushValue(task,value){
    if(value==null)module._hydronium_task_push_nil(task);else if(typeof value==="boolean")module._hydronium_task_push_boolean(task,value?1:0);else if(typeof value==="number")module._hydronium_task_push_number(task,value);
    else if(typeof value==="string")encode(module,value,(p,n)=>module._hydronium_task_push_string(task,p,n));
    else if(value instanceof LuaFunctionHandle)module._hydronium_task_push_function_ref(task,value._referenceFor(engine));
    else if(value instanceof HostReference)module._hydronium_task_push_host_ref(task,value._idFor(engine));
    else if(typeof value==="function")encode(module,operationFor(value),(p)=>module._hydronium_task_push_host_function(task,module.UTF8ToString(p)));
    else if(typeof value==="object"){
      const reference=makeHostReference(value);
      try{module._hydronium_task_push_host_ref(task,reference._idFor(engine));}finally{reference.release();}
    }else throw new TypeError(`unsupported JavaScript value: ${typeof value}`);
  }
  const hostFunction=module.addFunction((thread,namePointer,nameLength,firstIndex,argumentCount)=>{
    const id=nextHostOperation++,name=module.UTF8ToString(namePointer,nameLength),binding=hostBindings.get(name),context=activeContext;
    let args;try{args=Array.from({length:argumentCount},(_,offset)=>readStackValue(thread,firstIndex+offset));}catch(error){const promise=Promise.reject(error);promise.catch(()=>{});hostOperations.set(id,promise);return id;}
    const promise=Promise.resolve().then(()=>{if(!binding)throw new Error(`unknown host operation: ${name}`);if(!context)throw new Error("host operation started outside a scheduled Lua resume");if(context.signal.aborted)throw cancelled(context.signal);return binding(args,{signal:context.signal,owner:context.owner,generation:context.generation});});
    promise.catch(()=>{});hostOperations.set(id,promise);return id;
  },"iiiiii");
  const hostRefRetainFunction=module.addFunction((id)=>retainHostReference(id),"vi");
  const hostRefReleaseFunction=module.addFunction((id)=>releaseHostReference(id),"vi");
  const hostFunctionReleaseFunction=module.addFunction((pointer,length)=>hostBindings.delete(decode(pointer,length)),"vii");
  module._hydronium_task_set_host_start(hostFunction);
  module._hydronium_task_set_host_ref_callbacks(hostRefRetainFunction,hostRefReleaseFunction);
  module._hydronium_task_set_host_function_release(hostFunctionReleaseFunction);
  async function waitForHost(id,signal){const operation=hostOperations.get(id);if(!operation)throw new Error(`Lua yielded unknown host operation ${id}`);let rejectCancellation;const cancellation=new Promise((_,reject)=>{rejectCancellation=reject;});const onAbort=()=>rejectCancellation(cancelled(signal));if(signal.aborted)onAbort();else signal.addEventListener("abort",onAbort,{once:true});try{return await Promise.race([operation,cancellation]);}finally{signal.removeEventListener("abort",onAbort);hostOperations.delete(id);}}

  async function driveTask(create,initialArgs,{signal:externalSignal,deadlineMs,owner,generation}={}){
    if(closed)throw new Error("Lua task engine is closed");
    const controller=new AbortController(),forward=()=>controller.abort(externalSignal.reason);if(externalSignal?.aborted)forward();else externalSignal?.addEventListener("abort",forward,{once:true});
    let timer;if(deadlineMs!=null){if(!Number.isFinite(deadlineMs)||deadlineMs<0)throw new TypeError("deadlineMs must be non-negative");timer=setTimeout(()=>controller.abort(`Lua task deadline exceeded after ${deadlineMs} ms`),deadlineMs);}
    const context={controller,signal:controller.signal,owner,generation};activeRuns.add(context);let task;
    try{task=await enqueue(create);if(!task)throw new Error("Lua task creation failed");let resume,first=true;
      while(true){if(controller.signal.aborted)throw cancelled(controller.signal);const outcome=await enqueue(()=>{activeContext=context;try{let count=0;if(first){for(const value of initialArgs)pushValue(task,value);count=initialArgs.length;first=false;}else if(resume){module._hydronium_task_prepare_resume(task);module._hydronium_task_push_boolean(task,resume.ok?1:0);pushValue(task,resume.value);count=2;}const status=module._hydronium_task_resume(task,count);if(status===DONE)return{status,value:readValue(task)};if(status===YIELDED)return{status,id:module._hydronium_task_yield_id(task)};return{status,error:readValue(task)};}finally{activeContext=undefined;}});
        if(outcome.status===DONE)return outcome.value;if(outcome.status!==YIELDED)throw new Error(String(outcome.error??"Lua task failed"));try{resume={ok:true,value:await waitForHost(outcome.id,controller.signal)};}catch(error){if(controller.signal.aborted)throw cancelled(controller.signal);resume={ok:false,value:error?.message??String(error)};}}
    }finally{if(task)await enqueue(()=>module._hydronium_task_release(task));if(timer)clearTimeout(timer);externalSignal?.removeEventListener("abort",forward);activeRuns.delete(context);}
  }
  function withCString(value,callback){
    const text=String(value);if(text.includes("\0"))throw new TypeError("Lua global names and callback names must be NUL-free");
    return encode(module,text,(pointer)=>callback(pointer));
  }
  function setGlobal(name,value){
    if(closed)throw new Error("Lua task engine is closed");
    withCString(name,(namePointer)=>{
      if(value==null){module._hydronium_global_set_nil(state,namePointer);return;}
      if(typeof value==="boolean"){module._hydronium_global_set_boolean(state,namePointer,value?1:0);return;}
      if(typeof value==="number"){module._hydronium_global_set_number(state,namePointer,value);return;}
      if(typeof value==="string"){encode(module,value,(pointer,length)=>module._hydronium_global_set_string(state,namePointer,pointer,length));return;}
      if(value instanceof LuaFunctionHandle){module._hydronium_global_set_function_ref(state,namePointer,value._referenceFor(engine));return;}
      if(value instanceof HostReference){module._hydronium_global_set_host_ref(state,namePointer,value._idFor(engine));return;}
      if(typeof value==="function"){
        const operation=operationFor(value);withCString(operation,(operationPointer)=>module._hydronium_global_set_host_function(state,namePointer,operationPointer));return;
      }
      if(typeof value==="object"){
        const reference=makeHostReference(value);
        try{module._hydronium_global_set_host_ref(state,namePointer,reference._idFor(engine));}finally{reference.release();}
        return;
      }
      throw new TypeError(`unsupported Lua global value: ${typeof value}`);
    });
  }
  function getGlobal(name){
    if(closed)throw new Error("Lua task engine is closed");
    return withCString(name,(namePointer)=>{
      switch(module._hydronium_global_get_type(state,namePointer)){
        case NIL:return undefined;
        case BOOLEAN:return module._hydronium_global_get_boolean(state,namePointer)!==0;
        case NUMBER:return module._hydronium_global_get_number(state,namePointer);
        case STRING:return decode(module._hydronium_global_get_string(state,namePointer),module._hydronium_global_get_string_length(state,namePointer));
        case FUNCTION:return retainFunction(module._hydronium_global_get_function_ref(state,namePointer));
        case HOST_REF:{const entry=hostReferences.get(module._hydronium_global_get_host_ref(state,namePointer));if(!entry)throw new Error("unknown or released host reference");return entry.value;}
        default:throw new TypeError(`unsupported Lua global value: ${String(name)}`);
      }
    });
  }
  engine={api:2,module,
    bind(name,callback){if(closed)throw new Error("Lua task engine is closed");if(typeof name!=="string"||typeof callback!=="function")throw new TypeError("bind requires a name and function");hostBindings.set(name,callback);return()=>hostBindings.delete(name);},
    hostRef(value){if(closed)throw new Error("Lua task engine is closed");if((typeof value!=="object"&&typeof value!=="function")||value===null)throw new TypeError("hostRef requires an object or function");return makeHostReference(value);},
    global:Object.freeze({set:setGlobal,get:getGlobal}),
    doString(source){return engine.run(source);},
    version(){return module.UTF8ToString(module._hydronium_lua_version());},
    scope(metadata={}){if(closed)throw new Error("Lua task engine is closed");return new LuaTaskScope(engine,metadata);},
    run(source,{chunkName="=(hydronium-task)",...options}={}){if(typeof source!=="string"||source.includes("\0")||typeof chunkName!=="string"||chunkName.includes("\0"))throw new TypeError("task source and chunk name must be NUL-free strings");return driveTask(()=>encode(module,source,p=>encode(module,chunkName,c=>module._hydronium_task_create(state,p,c))),[],options);},
    async close(){if(closed)return;closed=true;for(const context of activeRuns)context.controller.abort("Lua task engine closed");while(activeRuns.size)await new Promise(resolve=>setTimeout(resolve,0));await enqueue(()=>{for(const handle of [...functionHandles])handle._close();module._hydronium_task_set_host_start(0);module._hydronium_lua_close(state);module._hydronium_task_set_host_ref_callbacks(0,0);module._hydronium_task_set_host_function_release(0);module.removeFunction(hostFunction);module.removeFunction(hostRefRetainFunction);module.removeFunction(hostRefReleaseFunction);module.removeFunction(hostFunctionReleaseFunction);});hostBindings.clear();hostOperations.clear();hostReferences.clear();}
  };
  return engine;
}
