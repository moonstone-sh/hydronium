// Runs inside the VS Code extension host (see run.mjs). Every check is a
// real editor operation against a real lua-language-server.
const vscode = require("vscode");
const { writeFileSync } = require("node:fs");
const path = require("node:path");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, timeout = 60000, step = 250) {
  const end = Date.now() + timeout;
  let last;
  while (Date.now() < end) {
    try { last = await fn(); if (last) return last; } catch (e) { last = e; }
    await sleep(step);
  }
  return null;
}

async function open(name) {
  const root = vscode.workspace.workspaceFolders[0].uri;
  const doc = await vscode.workspace.openTextDocument(vscode.Uri.joinPath(root, name));
  const editor = await vscode.window.showTextDocument(doc);
  return { doc, editor };
}

async function setText(editor, text) {
  await editor.edit((b) => b.replace(new vscode.Range(0, 0, editor.document.lineCount, 0), text));
}

exports.run = async function run() {
  const checks = [];
  const check = async (name, fn) => {
    try {
      const detail = await fn();
      checks.push({ name, ok: true, detail: typeof detail === "string" ? detail : "" });
    } catch (error) {
      checks.push({ name, ok: false, detail: String(error && error.message || error) });
    }
  };
  const ext = vscode.extensions.all.find((e) => e.packageJSON.name === "hydronium-luax");

  await check("activates on a .luax file with language id luax", async () => {
    const { doc } = await open("App.luax");
    if (doc.languageId !== "luax") throw new Error(`languageId ${doc.languageId}`);
    await until(() => ext.isActive, 20000);
    if (!ext.isActive) throw new Error("not active");
  });

  await check("diagnostics: the bad prop is reported at its column, the good file is clean", async () => {
    const { doc } = await open("App.luax");
    const diags = await until(() => {
      const d = vscode.languages.getDiagnostics(doc.uri).filter((x) => /assign-type-mismatch|param-type-mismatch/.test(String(x.code && x.code.value || x.code)));
      return d.length ? d : null;
    }, 90000);
    if (!diags) {
      const all = vscode.languages.getDiagnostics().map(([uri, list]) => `${uri.toString()} (${list.length}): ${list.map((d) => d.message.split("\n")[0]).join(" | ")}`);
      throw new Error(`no type diagnostic on ${doc.uri.toString()}; all: ${JSON.stringify(all)}`);
    }
    const at = diags[0].range.start;
    const line = doc.lineAt(at.line).text;
    if (!line.slice(at.character).startsWith("disabled")) throw new Error(`at ${at.line}:${at.character} "${line.slice(at.character, at.character + 12)}"`);
    const good = (await open("Good.luax")).doc;
    await sleep(3000);
    const extra = vscode.languages.getDiagnostics(good.uri).filter((d) => d.severity <= vscode.DiagnosticSeverity.Warning);
    if (extra.length) throw new Error("Good.luax: " + extra.map((d) => d.message).join("; "));
    return `${diags.length} on App.luax at ${at.line + 1}:${at.character + 1}`;
  });

  await check("completion after <d. offers DOM tags", async () => {
    const { doc, editor } = await open("Complete.luax");
    await setText(editor, "return <d.\n");
    const position = new vscode.Position(0, "return <d.".length);
    const list = await until(async () => {
      const r = await vscode.commands.executeCommand("vscode.executeCompletionItemProvider", doc.uri, position, ".");
      const labels = r.items.map((i) => (typeof i.label === "string" ? i.label : i.label.label));
      return labels.includes("button") && labels.includes("div") ? labels : null;
    }, 30000);
    if (!list) throw new Error("no button/div in completion");
    return `${list.length} items`;
  });

  await check("hover on a tag shows its props type", async () => {
    const { doc } = await open("Good.luax");
    const text = doc.getText();
    const position = doc.positionAt(text.indexOf("d.button") + 3);
    const hover = await until(async () => {
      const hovers = await vscode.commands.executeCommand("vscode.executeHoverProvider", doc.uri, position);
      const value = hovers.flatMap((h) => h.contents.map((c) => (typeof c === "string" ? c : c.value))).join("\n");
      return /HTMLButtonProps|HTMLButtonElement|Intrinsic/.test(value) ? value : null;
    }, 30000);
    if (!hover) throw new Error("hover without the button types");
    return hover.split("\n").find((l) => /Intrinsic|HTMLButton/.test(l)).trim().slice(0, 100);
  });

  await check("linked editing: typing in the opening tag renames the closing tag", async () => {
    const { doc, editor } = await open("Complete.luax");
    await setText(editor, "return <d.div><d.p>x</d.p></d.div>\n");
    const at = doc.positionAt("return <d.div><d.p".length);
    editor.selection = new vscode.Selection(at, at);
    // Linked editing ranges are computed after the cursor settles; type one
    // character at a time like a person would.
    await sleep(1500);
    await vscode.commands.executeCommand("type", { text: "r" });
    await sleep(300);
    await vscode.commands.executeCommand("type", { text: "e" });
    const ok = await until(() => doc.lineAt(0).text === "return <d.div><d.pre>x</d.pre></d.div>" ? true : null, 5000);
    if (!ok) throw new Error(doc.lineAt(0).text);
  });

  await check("typing > closes the tag", async () => {
    const { doc, editor } = await open("Complete.luax");
    // Typed one character at a time, so bracket auto-pairing applies as it would for a person.
    await setText(editor, "return \n");
    editor.selection = new vscode.Selection(0, "return ".length, 0, "return ".length);
    for (const ch of "<d.article>") await vscode.commands.executeCommand("type", { text: ch });
    const done = await until(() => doc.getText().startsWith("return <d.article></d.article>") ? true : null, 5000);
    if (!done) throw new Error(JSON.stringify(doc.lineAt(0).text));
    const cursor = editor.selection.active.character;
    if (cursor !== "return <d.article>".length) throw new Error(`cursor at ${cursor}`);
  });

  await check("rename, unwrap and remove tag commands", async () => {
    const { doc, editor } = await open("Complete.luax");
    const src = 'return <d.div><d.p class="x">a<d.b>b</d.b></d.p></d.div>\n';
    const at = (needle) => {
      const p = doc.positionAt(doc.getText().indexOf(needle) + 1);
      editor.selection = new vscode.Selection(p, p);
    };
    await setText(editor, src);
    at("d.p");
    await vscode.commands.executeCommand("hydroniumLuax.renameTag", "d.section");
    let text = doc.lineAt(0).text;
    if (text !== 'return <d.div><d.section class="x">a<d.b>b</d.b></d.section></d.div>') throw new Error("rename: " + text);
    at("d.section");
    await vscode.commands.executeCommand("hydroniumLuax.unwrapTag");
    text = doc.lineAt(0).text;
    if (text !== "return <d.div>a<d.b>b</d.b></d.div>") throw new Error("unwrap: " + text);
    at("d.b");
    await vscode.commands.executeCommand("hydroniumLuax.removeTag");
    text = doc.lineAt(0).text;
    if (text !== "return <d.div>a</d.div>") throw new Error("remove: " + text);
  });

  await check("one language server instance reports each .luax problem once", async () => {
    const { doc } = await open("App.luax");
    const all = vscode.languages.getDiagnostics(doc.uri).filter((d) => d.range.start.line === 4 && /disabled/.test(doc.lineAt(4).text.slice(d.range.start.character)));
    const seen = new Set(all.map((d) => `${d.range.start.character}:${d.message}`));
    if (seen.size !== all.length) throw new Error(`duplicates: ${all.length} vs ${seen.size}`);
  });

  writeFileSync(process.env.HYDRONIUM_LUAX_RESULTS, JSON.stringify(checks, null, 2));
};
