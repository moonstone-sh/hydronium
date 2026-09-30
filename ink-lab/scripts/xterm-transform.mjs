// xterm 6.0.0 measures pointer offsets in screen pixels but divides by
// untransformed cell metrics. Normalize them at the coordinate boundary so
// selection, mouse reporting and links all use the same local coordinates.
// Keep the installed dependency intact; fail builds if its implementation changes.
export function patchXtermCoordinates(source) {
  const before='return[t.clientX-i.left-n,t.clientY-i.top-o]';
  const after='return[(t.clientX-i.left)/(i.width/e.offsetWidth||1)-n,(t.clientY-i.top)/(i.height/e.offsetHeight||1)-o]';
  if(source.split(before).length!==2)throw new Error('xterm coordinate compatibility patch requires review for this distribution');
  return source.replace(before,after);
}
