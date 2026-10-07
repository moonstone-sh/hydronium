// lua-language-server in the browser: Lua 5.5 + lpeglabel compiled to wasm,
// with three bridges to the JavaScript host (a Web Worker):
//
//   luals_invoke(fn, data, len)   JS -> Lua: calls LUALS[fn](bytes), returns bytes
//   __host_emit(text)             Lua -> JS: an LSP message or a log line
//   __host_now()                  Lua -> JS: monotonic whole milliseconds
//
// Everything else (filesystem, bee.*, the event loop) is Lua: shim.lua and
// boot.lua, loaded from the bundle.
#include <stdlib.h>
#include <string.h>
#include <emscripten.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

int luaopen_lpeglabel(lua_State *L);

EM_JS(void, js_emit, (int kind, const char *ptr, size_t len), {
  Module.onLualsEmit(kind, UTF8ToString(ptr, len));
});
EM_JS(double, js_now, (void), { return Math.floor(performance.now()); });

static lua_State *L;
static char *result;
static size_t result_len;

static int host_emit(lua_State *L) {
  size_t len;
  int kind = (int)luaL_checkinteger(L, 1);
  const char *s = luaL_checklstring(L, 2, &len);
  js_emit(kind, s, len);
  return 0;
}
static int host_now(lua_State *L) { lua_pushinteger(L, (lua_Integer)js_now()); return 1; }
static int new_userdata(lua_State *L) { lua_newuserdatauv(L, 0, 0); return 1; }

static int traceback(lua_State *L) {
  luaL_traceback(L, L, lua_tostring(L, 1), 1);
  return 1;
}

EMSCRIPTEN_KEEPALIVE int luals_init(void) {
  L = luaL_newstate();
  if (!L) return 1;
  luaL_openlibs(L);
  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, luaopen_lpeglabel);
  lua_setfield(L, -2, "lpeglabel");
  lua_pop(L, 1);
  lua_register(L, "__host_emit", host_emit);
  lua_register(L, "__host_now", host_now);
  lua_register(L, "__luals_newuserdata", new_userdata);
  lua_newtable(L);
  lua_setglobal(L, "LUALS");
  return 0;
}

// Runs a chunk (the bootstrap: shim + mount + boot). Returns 0 or sets the
// error as the result.
EMSCRIPTEN_KEEPALIVE int luals_run(const char *code, size_t len, const char *name) {
  lua_pushcfunction(L, traceback);
  int base = lua_gettop(L);
  int status = luaL_loadbuffer(L, code, len, name);
  if (status == LUA_OK) status = lua_pcall(L, 0, 0, base);
  if (status != LUA_OK) {
    size_t n;
    const char *msg = lua_tolstring(L, -1, &n);
    free(result);
    result = malloc(n + 1);
    memcpy(result, msg, n);
    result[n] = 0;
    result_len = n;
  }
  lua_settop(L, base - 1);
  return status;
}

// LUALS[fn](data) -> string result (or error). The result stays valid until
// the next call.
EMSCRIPTEN_KEEPALIVE int luals_invoke(const char *fn, const char *data, size_t len) {
  lua_pushcfunction(L, traceback);
  int base = lua_gettop(L);
  lua_getglobal(L, "LUALS");
  lua_getfield(L, -1, fn);
  lua_remove(L, -2);
  if (data) lua_pushlstring(L, data, len); else lua_pushnil(L);
  int status = lua_pcall(L, 1, 1, base);
  size_t n = 0;
  const char *s = lua_isstring(L, -1) ? lua_tolstring(L, -1, &n) : (lua_toboolean(L, -1) ? "true" : "");
  free(result);
  result = malloc(n + 1);
  memcpy(result, s, n);
  result[n] = 0;
  result_len = n;
  lua_settop(L, base - 1);
  return status;
}

EMSCRIPTEN_KEEPALIVE const char *luals_result(void) { return result; }
EMSCRIPTEN_KEEPALIVE size_t luals_result_len(void) { return result_len; }
