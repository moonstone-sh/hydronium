// Hydronium LUAX for VS Code and VSCodium.
//
// The language intelligence Neovim gets from lua-language-server plus
// Hydronium's LuaLS plugin, here through a LanguageClient of our own: the
// sumneko.lua extension only sends documents whose language is "lua", and
// `.luax` keeps its own language (grammar, tag brackets). The server binary
// is the one sumneko.lua ships, `hydroniumLuax.server.path`, or
// lua-language-server on PATH.
//
// A project's .luarc.json (what `hydronium create` writes) always wins:
// LuaLS ranks it above client settings. The defaults below only make a bare
// folder of .luax files work: the bundled plugin and type libraries.
//
// Tag editing (auto-close, linked rename, remove/unwrap/rename commands)
// comes from luax/editor/luax-tags.mjs, the scanner the browser playground
// uses too.
import * as vscode from "vscode";
import { LanguageClient, TransportKind } from "vscode-languageclient/node";
import { existsSync } from "node:fs";
import { join, delimiter } from "node:path";
import {
  scan, linkedNameRanges, autoCloseTag, removeTagEdits, unwrapTagEdits, renameTagEdits, elementAt,
} from "../../../../luax/editor/luax-tags.mjs";

const LANGUAGE = "luax";
const SELECTOR = [{ scheme: "file", language: LANGUAGE }, { scheme: "file", pattern: "**/*.mdx" }];
const TAG_NAME = /[A-Za-z_][A-Za-z0-9_.-]*/;

let client = null;
let output = null;

function serverPath(context) {
  const configured = vscode.workspace.getConfiguration("hydroniumLuax").get("server.path");
  if (configured) return existsSync(configured) ? configured : null;
  const exe = process.platform === "win32" ? "lua-language-server.exe" : "lua-language-server";
  const sumneko = vscode.extensions.getExtension("sumneko.lua");
  if (sumneko) {
    const bundled = join(sumneko.extensionPath, "server", "bin", exe);
    if (existsSync(bundled)) return bundled;
  }
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    const candidate = join(dir, exe);
    if (dir && existsSync(candidate)) return candidate;
  }
  return null;
}

/** Defaults merged under the user's own `Lua` settings. */
function luaDefaults(context) {
  const root = context.extensionPath;
  return {
    runtime: {
      version: "LuaJIT",
      path: ["?.lua", "?/init.lua", "?.luax", "?/init.luax"],
      plugin: join(root, "src", "hydronium_luax", "luals", "init.lua"),
    },
    workspace: {
      library: [
        ...["core", "luax", "dom"].map((name) => join(root, "dist", "types", name)),
        ...["core", "dom"].map((name) => join(root, "dist", "lib", name)),
      ],
      checkThirdParty: false,
    },
    diagnostics: { globals: ["__luax", "__luax_component", "__luax_fragment"] },
    // WebGL contexts have ~450 members; LuaLS's default (100) withholds member
    // completion on larger objects until a prefix is typed.
    completion: { maxSuggestCount: 1000 },
  };
}

function merge(base, over) {
  if (Array.isArray(base) && Array.isArray(over)) return [...new Set([...base, ...over])];
  if (base && over && typeof base === "object" && typeof over === "object" && !Array.isArray(base)) {
    const out = { ...base };
    for (const [key, value] of Object.entries(over)) out[key] = key in base ? merge(base[key], value) : value;
    return out;
  }
  return over === undefined || over === null || over === "" ? base : over;
}

async function startClient(context) {
  const command = serverPath(context);
  if (!command) {
    const pick = await vscode.window.showWarningMessage(
      "Hydronium LUAX needs lua-language-server for completion, hover and diagnostics. Install the Lua extension (sumneko.lua), or set hydroniumLuax.server.path.",
      "Install Lua extension",
    );
    if (pick) await vscode.commands.executeCommand("workbench.extensions.search", "sumneko.lua");
    return;
  }
  const defaults = luaDefaults(context);
  client = new LanguageClient("hydroniumLuax", "Hydronium LUAX", { command, transport: TransportKind.stdio }, {
    documentSelector: SELECTOR,
    outputChannel: output,
    // LuaLS asks before running a plugin unless the client vouches for it.
    // Vouch only in a trusted workspace: a project's .luarc.json can point
    // runtime.plugin at any file. In Restricted Mode LuaLS asks as usual.
    initializationOptions: { trustByClient: vscode.workspace.isTrusted },
    middleware: {
      // With sumneko.lua installed, its own server reports .lua files; this
      // one keeps to .luax/.mdx so nothing is reported twice. (Turning off
      // LuaLS's workspace pass instead would also skip files opened before
      // the workspace finished loading.)
      handleDiagnostics: (uri, diagnostics, next) => {
        const owned = /\.(luax|mdx)$/.test(uri.path) || !vscode.extensions.getExtension("sumneko.lua");
        next(uri, owned ? diagnostics : []);
      },
      workspace: {
        configuration: async (params, token, next) => {
          const results = await next(params, token);
          return params.items.map((item, index) => {
            const value = Array.isArray(results) ? results[index] : null;
            // The user's sumneko.lua settings, over our defaults.
            if (item.section === "Lua") return merge(defaults, value || {});
            if (item.section === "files.associations") return { ...(value || {}), "*.luax": "lua", "*.mdx": "lua" };
            return value;
          });
        },
      },
    },
  });
  await client.start();
}

// Format Document for .luax: Hydronium's LUAX formatter (the same one
// `luax format` runs), executed by the wasm Lua engine bundled in
// dist/engine, over the formatter sources the extension already ships in src/.
let formatterEngine = null;
async function luaxFormatter(context) {
  formatterEngine ||= (async () => {
    const { readFileSync, readdirSync, statSync } = await import("node:fs");
    const { pathToFileURL } = await import("node:url");
    const engineDir = join(context.extensionPath, "dist", "engine");
    // A runtime import: the engine is an ES module next to this bundle.
    const load = new Function("url", "return import(url)");
    const { default: createModule } = await load(pathToFileURL(join(engineDir, "luals.mjs")).href);
    const M = await createModule({ locateFile: (file) => join(engineDir, file), onLualsEmit() {} });
    const enc = new TextEncoder();
    const withBuffer = (data, fn) => {
      const bytes = typeof data === "string" ? enc.encode(data) : data;
      const ptr = M._malloc(bytes.length + 1);
      M.HEAPU8.set(bytes, ptr);
      M.HEAPU8[ptr + bytes.length] = 0;
      try { return fn(ptr, bytes.length); } finally { M._free(ptr); }
    };
    const result = () => M.UTF8ToString(M._luals_result(), M._luals_result_len());
    const invoke = (fn, data) => withBuffer(fn, (fp) => withBuffer(data, (p, n) => {
      if (M._luals_invoke(fp, p, n) !== 0) throw new Error(result());
      return result();
    }));
    if (M._luals_init() !== 0) throw new Error("formatter engine failed to start");
    withBuffer(readFileSync(join(engineDir, "shim.lua")), (p, n) => withBuffer("@/luals/shim.lua", (np) => {
      if (M._luals_run(p, n, np) !== 0) throw new Error(result());
    }));
    const src = join(context.extensionPath, "src");
    const walk = (dir) => {
      for (const name of readdirSync(dir)) {
        const path = join(dir, name);
        if (statSync(path).isDirectory()) walk(path);
        else if (name.endsWith(".lua")) invoke("write", `/hydronium/luax/src${path.slice(src.length)}\0${readFileSync(path, "utf8")}`);
      }
    };
    walk(src);
    return (text) => invoke("format_luax", text);
  })();
  return formatterEngine;
}

function formatting(context) {
  return vscode.languages.registerDocumentFormattingEditProvider(LANGUAGE, {
    async provideDocumentFormattingEdits(document) {
      const original = document.getText();
      let text;
      try {
        text = (await luaxFormatter(context))(original);
      } catch (error) {
        vscode.window.showWarningMessage(`Hydronium LUAX: cannot format (${String(error.message || error).split("\n")[0]})`);
        return [];
      }
      if (original.endsWith("\n") && !text.endsWith("\n")) text += "\n";
      if (text === original) return [];
      return [vscode.TextEdit.replace(new vscode.Range(document.positionAt(0), document.positionAt(original.length)), text)];
    },
  });
}

// Linked editing: typing in `<d.div>` renames `</d.div>`.
function linkedEditing() {
  return vscode.languages.registerLinkedEditingRangeProvider(LANGUAGE, {
    provideLinkedEditingRanges(document, position) {
      const text = document.getText();
      const ranges = linkedNameRanges(text, document.offsetAt(position));
      if (!ranges) return null;
      return new vscode.LinkedEditingRanges(
        ranges.map((r) => new vscode.Range(document.positionAt(r.start), document.positionAt(r.end))),
        TAG_NAME,
      );
    },
  });
}

// `>` closes the element just opened: `<d.div>` -> `<d.div>|</d.div>`.
function autoClose() {
  return vscode.workspace.onDidChangeTextDocument((event) => {
    if (event.document.languageId !== LANGUAGE || event.reason) return; // reason is set for undo/redo
    if (!vscode.workspace.getConfiguration("hydroniumLuax", event.document).get("autoCloseTags", true)) return;
    const change = event.contentChanges[event.contentChanges.length - 1];
    // Only a typed `>`: an auto-inserted or pasted `>` is not the end of a tag being written.
    if (!change || event.contentChanges.length !== 1 || change.text !== ">" || change.rangeLength > 0) return;
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document !== event.document) return;
    const document = event.document;
    const offset = document.offsetAt(change.range.start) + change.text.length;
    const close = autoCloseTag(document.getText(), offset);
    if (!close) return;
    const position = document.positionAt(offset);
    editor.edit((builder) => builder.insert(position, close), { undoStopBefore: false, undoStopAfter: false })
      .then((ok) => { if (ok) editor.selection = new vscode.Selection(position, position); });
  });
}

async function applyEdits(editor, edits) {
  if (!edits || edits.length === 0) {
    vscode.window.showInformationMessage("Hydronium LUAX: no tag at the cursor.");
    return false;
  }
  const document = editor.document;
  return editor.edit((builder) => {
    for (const e of edits) builder.replace(new vscode.Range(document.positionAt(e.start), document.positionAt(e.end)), e.text);
  });
}

// Plain commands on the active editor: a TextEditorCommand applies its own
// edit when the callback returns, which would cancel these async edits.
function tagCommands() {
  const offsetOf = (editor) => editor.document.offsetAt(editor.selection.active);
  const withEditor = (fn) => (...args) => {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== LANGUAGE) return;
    return fn(editor, ...args);
  };
  return [
    vscode.commands.registerCommand("hydroniumLuax.removeTag", withEditor((editor) =>
      applyEdits(editor, removeTagEdits(editor.document.getText(), offsetOf(editor))))),
    vscode.commands.registerCommand("hydroniumLuax.unwrapTag", withEditor((editor) => {
      const text = editor.document.getText();
      const hit = elementAt(text, offsetOf(editor));
      if (hit && hit.element.selfClosing) {
        vscode.window.showInformationMessage("Hydronium LUAX: a self-closing tag has no children to keep.");
        return;
      }
      return applyEdits(editor, unwrapTagEdits(text, offsetOf(editor)));
    })),
    vscode.commands.registerCommand("hydroniumLuax.renameTag", withEditor(async (editor, newName) => {
      const text = editor.document.getText();
      const hit = elementAt(text, offsetOf(editor));
      if (!hit || hit.element.fragment) {
        vscode.window.showInformationMessage("Hydronium LUAX: no named tag at the cursor.");
        return;
      }
      const name = newName ?? await vscode.window.showInputBox({ prompt: "New tag name", value: hit.element.name, validateInput: (v) => (/^[A-Za-z_][A-Za-z0-9_-]*(\.[A-Za-z_][A-Za-z0-9_-]*)*$/.test(v) ? null : "Not a tag name") });
      if (!name) return;
      return applyEdits(editor, renameTagEdits(text, offsetOf(editor), name));
    })),
    vscode.commands.registerCommand("hydroniumLuax.restartServer", async () => {
      if (client) await client.stop();
      client = null;
      await startClient(globalThis.__hydroniumLuaxContext);
    }),
  ];
}

export async function activate(context) {
  globalThis.__hydroniumLuaxContext = context;
  output = vscode.window.createOutputChannel("Hydronium LUAX");
  context.subscriptions.push(output, linkedEditing(), autoClose(), formatting(context), ...tagCommands());
  context.subscriptions.push(vscode.workspace.onDidGrantWorkspaceTrust(() =>
    vscode.commands.executeCommand("hydroniumLuax.restartServer")));
  await startClient(context);
  // For tests and other extensions: the scanner and the running client.
  return { scan, client: () => client };
}

export async function deactivate() {
  if (client) await client.stop();
}
