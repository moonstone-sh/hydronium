/**
 * Minimal Source Map v3 reader — just enough to answer "which `.luax` line is
 * this generated Lua line?", which is all the dev error overlay needs.
 *
 * WHY HAND-ROLLED. This ships into a browser alongside a WASM Lua VM and must
 * work with no bundler at all (see overlay.js and this package's own
 * package.json). Pulling a source-map library in for one line lookup would add
 * a dependency to a package that deliberately has exactly one. The format is
 * small and stable; the part we need is ~40 lines.
 *
 * WHAT IT DELIBERATELY DOES NOT DO. No column resolution, no name lookup, no
 * nearest-segment search within a line. A Lua traceback gives a LINE, so a
 * line is what this resolves. Anything finer would be invented precision.
 */

const B64 =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

const CHAR_TO_INT = new Map();
for (let i = 0; i < B64.length; i += 1) CHAR_TO_INT.set(B64[i], i);

/**
 * Decodes one base64-VLQ run into signed integers.
 * @param {string} segment
 * @returns {number[]}
 */
export function decodeVlq(segment) {
  const out = [];
  let shift = 0;
  let value = 0;
  for (const ch of segment) {
    const digit = CHAR_TO_INT.get(ch);
    if (digit === undefined) return out; // unknown char: stop rather than guess
    const hasContinuation = (digit & 32) !== 0;
    value += (digit & 31) << shift;
    if (hasContinuation) {
      shift += 5;
      continue;
    }
    // The low bit is the sign, and -0 encodes the minimum, not zero.
    const negative = (value & 1) === 1;
    value >>= 1;
    out.push(negative ? -value : value);
    value = 0;
    shift = 0;
  }
  return out;
}

/**
 * Resolves a 1-based generated line to its original file and 1-based line.
 *
 * Returns null when the map has no mapping for that line — an honest "I don't
 * know" that the overlay renders as the generated frame, rather than a
 * confidently wrong `.luax` line.
 *
 * @param {{ sources?: string[], mappings?: string }} map
 * @param {number} generatedLine 1-based, as a Lua traceback reports it
 * @returns {{ file: string, line: number } | null}
 */
export function originalPositionFor(map, generatedLine) {
  if (!map || typeof map.mappings !== "string") return null;
  if (!Number.isInteger(generatedLine) || generatedLine < 1) return null;

  const lines = map.mappings.split(";");
  const target = generatedLine - 1;
  if (target >= lines.length) return null;

  // srcIndex and srcLine are cumulative across the WHOLE map, not per line,
  // so every preceding line has to be walked even though only one is wanted.
  let srcIndex = 0;
  let srcLine = 0;
  for (let i = 0; i <= target; i += 1) {
    const group = lines[i];
    if (group === "") continue;
    let first = true;
    for (const seg of group.split(",")) {
      const fields = decodeVlq(seg);
      // [generatedColumn] alone carries no source position.
      if (fields.length < 4) continue;
      srcIndex += fields[1];
      srcLine += fields[2];
      if (i === target && first) {
        const file = (map.sources || [])[srcIndex];
        if (typeof file !== "string") return null;
        return { file, line: srcLine + 1 };
      }
      first = false;
    }
  }
  return null;
}

/**
 * Builds a `resolveFrame` for the error overlay.
 *
 * `mapUrlFor(moduleId)` returns where that module's map lives, or null when it
 * has none (a plain `.lua` module was never compiled from `.luax`, so there is
 * nothing to resolve and nothing to fetch).
 *
 * Resolution is synchronous because the overlay renders synchronously, so maps
 * are fetched and cached by `warm()` ahead of time. A frame whose map has not
 * been warmed simply stays unresolved — the overlay already renders that case
 * honestly.
 */
export function createSourceMapResolver({ mapUrlFor, fetchImpl } = {}) {
  const maps = new Map(); // moduleId -> map | null
  const doFetch = fetchImpl || ((...a) => fetch(...a));

  async function warm(moduleIds) {
    await Promise.all(
      (moduleIds || []).map(async (id) => {
        if (maps.has(id)) return;
        const url = mapUrlFor ? mapUrlFor(id) : null;
        if (!url) return void maps.set(id, null);
        try {
          const res = await doFetch(url);
          maps.set(id, res.ok ? await res.json() : null);
        } catch {
          // A missing or unparseable map must never be louder than the error
          // the overlay is trying to show.
          maps.set(id, null);
        }
      })
    );
  }

  return {
    warm,
    resolveFrame(frame) {
      if (!frame) return null;
      const map = maps.get(frame.module);
      if (!map) return null;
      return originalPositionFor(map, frame.line);
    },
  };
}
