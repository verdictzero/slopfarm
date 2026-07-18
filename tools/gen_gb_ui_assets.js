#!/usr/bin/env node
/*
 * Bake the native Game Boy UI from the web shell.
 *
 * Renders web/gb_shell.html (the same CSS the web build wraps the game in) in headless Chromium
 * and captures DISCRETE, transparent PNGs of every console part — case, screen bezel, D-pad, the
 * six face keys, the START/SELECT pill, the analog stick + nub, and the small captions — plus a
 * layout.json recording where each part sits relative to the shell. The Godot portrait shell
 * (scripts/gb_shell_ui.gd) composites those assets at those positions, so the native build looks
 * nearly identical to the web one.
 *
 * Usage (needs Playwright + a Chromium build):
 *   PW=/path/to/playwright CHROME=/path/to/chrome node tools/gen_gb_ui_assets.js
 * The two env vars are optional; sensible defaults for this repo's toolchain are tried first.
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(ROOT, 'sprites', 'gb_ui');
const DPR = 4;

function loadPlaywright() {
  const cands = [process.env.PW, '/opt/node22/lib/node_modules/playwright/index.js', 'playwright'].filter(Boolean);
  for (const c of cands) { try { return require(c); } catch (e) {} }
  throw new Error('playwright not found; set PW=/abs/path/to/playwright/index.js');
}
function chromePath() {
  const cands = [process.env.CHROME, '/opt/pw-browsers/chromium-1194/chrome-linux/chrome'].filter(Boolean);
  for (const c of cands) { try { if (fs.statSync(c).isFile()) return c; } catch (e) {} }
  return undefined; // let Playwright pick its bundled build
}

// Strip the Godot export template placeholders so the shell renders standalone.
function strippedShellHTML() {
  let html = fs.readFileSync(path.join(ROOT, 'web', 'gb_shell.html'), 'utf8');
  html = html.replace('<script src="$GODOT_URL"></script>', '');
  html = html.replace(/<!-- =+\s*\n\s*Godot engine bootstrap[\s\S]*?<\/script>/, '');
  html = html.replace(/\$GODOT_[A-Z_]+/g, '');
  return html;
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  const tmp = path.join(OUT, '_shell_render.html');
  fs.writeFileSync(tmp, strippedShellHTML());

  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ executablePath: chromePath(), args: ['--no-sandbox', '--force-color-profile=srgb'] });
  const p = await browser.newPage({ viewport: { width: 468, height: 1000, deviceScaleFactor: DPR } });
  await p.goto('file://' + tmp, { waitUntil: 'load' });
  try { await p.evaluate(() => document.fonts && document.fonts.ready); } catch (e) {}
  await p.waitForTimeout(500);
  await p.evaluate(() => {
    document.documentElement.style.background = 'transparent';
    document.body.style.background = 'transparent';
    const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); const k = [];
    while (w.nextNode()) { if (/GODOT|INCLUDE|\$G/.test(w.currentNode.nodeValue)) k.push(w.currentNode); }
    k.forEach(t => { if (t.parentNode) t.parentNode.removeChild(t); });
  });

  const boxOf = (sel) => p.$eval(sel, (el) => { const r = el.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; });
  const S = await boxOf('#shell');
  const rel = (b) => ({ x: +(b.x - S.x).toFixed(1), y: +(b.y - S.y).toFixed(1), w: +b.w.toFixed(1), h: +b.h.toFixed(1) });
  const placements = [];
  async function shoot(sel, name, id, pad) {
    pad = Object.assign({ t: 12, r: 12, b: 12, l: 12 }, pad || {});
    const box = await boxOf(sel);
    const clip = { x: Math.max(0, box.x - pad.l), y: Math.max(0, box.y - pad.t), width: box.w + pad.l + pad.r, height: box.h + pad.t + pad.b };
    await p.screenshot({ path: path.join(OUT, name), clip, omitBackground: true });
    if (id) placements.push({ asset: name, id, x: +(clip.x - S.x).toFixed(1), y: +(clip.y - S.y).toFixed(1), w: clip.width, h: clip.height });
    return box;
  }
  const setVis = (sels, v) => p.evaluate(([sels, v]) => sels.forEach((s) => { const e = document.querySelector(s); if (e) e.style.visibility = v; }), [sels, v]);

  // reference + case carry the cream body; capture them before the shell is made transparent.
  await shoot('#shell', 'reference_portrait.png', null, { t: 20, r: 20, b: 30, l: 20 });
  await setVis(['.screen-wrap', '.controls-left', '.controls-right', '.controls-sys'], 'hidden');
  await shoot('#shell', 'case.png', null, { t: 4, r: 4, b: 4, l: 4 });
  await setVis(['.screen-wrap', '.controls-left', '.controls-right', '.controls-sys'], '');

  // Drop the case body so the controls capture with nothing cream behind them.
  await p.addStyleTag({ content: '#shell{background:transparent!important;box-shadow:none!important;} #shell::before{display:none!important;}' });

  await shoot('.screen', 'bezel.png', 'screen', { t: 8, r: 8, b: 10, l: 8 });
  const glassBox = await boxOf('#glass');
  await shoot('#dpad', 'dpad.png', 'dpad', { t: 10, r: 10, b: 10, l: 10 });
  for (const id of ['A', 'B', 'X', 'Y', 'Z', 'C']) {
    await p.evaluate((id) => document.querySelectorAll('.btn small').forEach((s) => { s.style.visibility = (s.parentElement.dataset.btn === id) ? '' : 'hidden'; }), id);
    await shoot(`[data-btn="${id}"]`, `btn_${id}.png`, 'btn_' + id, { t: 6, r: 14, b: 24, l: 14 });
  }
  await p.evaluate(() => document.querySelectorAll('.btn small').forEach((s) => { s.style.visibility = ''; }));

  await shoot('.pill', 'pill.png', null, { t: 14, r: 14, b: 14, l: 14 });
  { const bs = await p.$$eval('.pill', (els) => els.map((e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; }));
    ['select', 'start'].forEach((nm, i) => { const q = bs[i]; placements.push({ asset: 'pill.png', id: 'pill_' + nm, x: +(q.x - 14 - S.x).toFixed(1), y: +(q.y - 14 - S.y).toFixed(1), w: q.w + 28, h: q.h + 28 }); }); }

  await p.evaluate(() => { const n = document.querySelector('#stickL .nub'); if (n) n.style.visibility = 'hidden'; });
  await shoot('#stickL', 'stick_base.png', null, { t: 10, r: 10, b: 10, l: 10 });
  await p.evaluate(() => { const n = document.querySelector('#stickL .nub'); if (n) n.style.visibility = ''; });
  await shoot('#stickL .nub', 'stick_nub.png', null, { t: 8, r: 8, b: 8, l: 8 });
  { const bs = await p.$$eval('.stick', (els) => els.map((e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }; }));
    ['left', 'right'].forEach((nm, i) => { const q = bs[i]; placements.push({ asset: 'stick_base.png', id: 'stick_' + nm, x: +(q.x - 10 - S.x).toFixed(1), y: +(q.y - 10 - S.y).toFixed(1), w: q.w + 20, h: q.h + 20 }); }); }

  await shoot('.controls-left .cap', 'cap_move.png', 'cap_move', { t: 4, r: 10, b: 4, l: 10 });
  await shoot('.controls-sys .pill-wrap:nth-child(1) .cap', 'cap_select.png', 'cap_select', { t: 4, r: 10, b: 4, l: 10 });
  await shoot('.controls-sys .pill-wrap:nth-child(2) .cap', 'cap_start.png', 'cap_start', { t: 4, r: 10, b: 4, l: 10 });

  const layout = { dpr: DPR, shell: { w: +S.w.toFixed(1), h: +S.h.toFixed(1) }, glass_in_shell: rel(glassBox), placements };
  fs.writeFileSync(path.join(OUT, 'layout.json'), JSON.stringify(layout, null, 1));
  fs.unlinkSync(tmp);
  await browser.close();
  console.log('gb_ui assets: shell ' + Math.round(S.w) + 'x' + Math.round(S.h) + ', ' + placements.length + ' placements ->', OUT);
})().catch((e) => { console.error(String(e).slice(0, 600)); process.exit(1); });
