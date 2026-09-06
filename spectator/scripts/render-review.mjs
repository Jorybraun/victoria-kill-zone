// Run against a local demo-mode Vite server. Optional argv[2] locates a bundled
// Playwright module; no production connection or player credentials are used.
import {mkdir,writeFile} from "node:fs/promises";
import {fileURLToPath} from "node:url";
const {chromium}=await import(process.argv[2] ?? "playwright");
const output=fileURLToPath(new URL("../evidence/008-arena-spectator/",import.meta.url));
await mkdir(output,{recursive:true});
const browser=await chromium.launch({headless:true,...(process.env.VKZ_CHROME_PATH ? {executablePath:process.env.VKZ_CHROME_PATH} : {})});
const results=[];
try {
  const page=await browser.newPage();
  const errors=[];page.on("pageerror",e=>errors.push(e.message));
  for (const [name,fixture,width,textScale] of [
    ["arena-desktop","arena",1280,1], ["arena-phone","arena",375,1],
    ["aligning-phone","arena-calibrating",375,1], ["paused-phone","arena-paused",375,1],
    ["results-desktop","arena-ended",1280,1],
    ["interrupted-phone","arena-degraded",375,1], ["restored-phone","arena-recovery",375,1], ["arena-phone-text-200","arena",375,2],
  ]) {
    await page.setViewportSize({width,height:900});
    await page.goto(`http://127.0.0.1:4179/?match=ARENA4&demo=${fixture}`);
    await page.getByLabel("Arena players").waitFor();
    await page.getByText("DEMO FIXTURE",{exact:true}).waitFor();
    if(fixture === "arena-degraded") await page.getByText("CONNECTION INTERRUPTED",{exact:true}).waitFor();
    if(fixture === "arena-recovery") await page.getByText("CONNECTION RESTORED",{exact:true}).waitFor();
    if(textScale!==1) await page.evaluate(scale=>{document.documentElement.style.fontSize=`${scale*100}%`;},textScale);
    const layout=await page.evaluate(()=>({width:innerWidth,scrollWidth:document.documentElement.scrollWidth,
      heading:document.querySelector("h1")?.textContent,
      overflowingContent:[...document.querySelectorAll(".player-card, .life-state, .event-panel, .match-status")].filter(n=>n.scrollWidth>n.clientWidth+1).map(n=>n.className),players:[...document.querySelectorAll(".player-card h2")].map(n=>n.textContent)}));
    if(layout.scrollWidth>width || layout.players.length!==4 || layout.overflowingContent.length) {
      const overflow=await page.evaluate(()=>[...document.querySelectorAll("body *")].filter(n=>n.getBoundingClientRect().right>innerWidth+1).map(n=>({tag:n.tagName,cls:n.className,right:n.getBoundingClientRect().right})).slice(0,20));
      await page.screenshot({path:`${output}/${name}.png`,fullPage:true,animations:"disabled"});
      throw new Error(`${name}: layout assertion failed ${JSON.stringify({layout,overflow})}`);
    }
    await page.screenshot({path:`${output}/${name}.png`,fullPage:true,animations:"disabled"});
    results.push({name,fixture,textScale,...layout});
  }
  if(errors.length) throw new Error(errors.join("\n"));
  await writeFile(`${output}/manifest.json`,JSON.stringify({browser:browser.version(),evidence:"Actual React components with deterministic demo snapshots in headless Chromium; not production-network or iPhone evidence.",results},null,2)+"\n");
  process.stdout.write(JSON.stringify(results,null,2)+"\n");
} finally {await browser.close();}
