export const STANDARD_VIEWPORTS = Object.freeze([
  {name:'Mobile',width:390,height:844},{name:'Small mobile',width:320,height:568},
  {name:'Tablet',width:768,height:1024},{name:'Laptop',width:1280,height:800},{name:'Desktop',width:1440,height:900},
].map(Object.freeze));
export function viewportGroups(story, user = []) {
  user = Array.isArray(user) ? user : [];
  const valid = size => Number.isInteger(size?.width) && Number.isInteger(size?.height) && size.width>=1 && size.width<=8192 && size.height>=1 && size.height<=8192;
  const storySizes=Array.isArray(story?.viewports)?story.viewports.filter(valid):[];
  return [{label:'Story-specific',sizes:storySizes.length?storySizes:[{name:'Default',width:800,height:600}]},{label:'Standard',sizes:STANDARD_VIEWPORTS},...(user.some(valid)?[{label:'User-defined',sizes:user.filter(valid)}]:[])];
}
