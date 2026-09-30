import { Terminal } from '@xterm/xterm';
import { Unicode11Addon } from '@xterm/addon-unicode11';
export function createTerminalAdapter(container, onData) {
  const terminal = new Terminal({ cols: 80, rows: 24, scrollback: 10000, fontSize: 14, lineHeight: 1.2, allowProposedApi: true, convertEol: false, theme: {background:'#111318',foreground:'#e5e7eb'} });
  terminal.loadAddon(new Unicode11Addon()); terminal.unicode.activeVersion = '11';
  container.style.fontSize = "14px"; container.style.lineHeight = "1.2";
  terminal.open(container);
  const input = terminal.onData(onData);
  let ligatures, chain = Promise.resolve();
  return {
    write(frame, done) {
      chain = chain.then(() => new Promise(resolve => {
        const size = frame.terminal || {columns: frame.width || terminal.cols, rows: frame.height || terminal.rows};
        if (frame.kind === 'full') terminal.reset();
        if (size.columns !== terminal.cols || size.rows !== terminal.rows) terminal.resize(size.columns, size.rows);
        terminal.write(frame.ansi || '', () => { done?.(); resolve(); });
      }));
      return chain;
    },
    font(value) { terminal.options.fontFamily = value; container.style.fontFamily = value; },
    ligatures(enabled) {
      if (enabled && ligatures === undefined) {
        const patterns = ['===', '!==', '=>', '->', '<-', '==', '!=', '<=', '>=', '::'];
        ligatures = terminal.registerCharacterJoiner(text => {
          const ranges = [];
          for (let i = 0; i < text.length; i++) { const match = patterns.find(pattern => text.startsWith(pattern, i)); if (match) { ranges.push([i, i + match.length]); i += match.length - 1; } }
          return ranges;
        });
      } else if (!enabled && ligatures !== undefined) { terminal.deregisterCharacterJoiner(ligatures); ligatures = undefined; }
      terminal.element.style.fontFeatureSettings = enabled ? '"liga" 1, "calt" 1' : '"liga" 0, "calt" 0';
    },
    hasScrollback() { return terminal.buffer.active.baseY > 0; },
    focus() { terminal.focus(); },
    dispose() { input.dispose(); terminal.dispose(); },
  };
}
