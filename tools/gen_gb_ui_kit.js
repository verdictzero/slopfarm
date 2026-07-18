#!/usr/bin/env node
/*
 * Rasterize the vector Game Boy control kit (tools/gb_ui_kit/*.svg) into the PNGs the native console
 * uses (sprites/gb_ui/), and generate the small caption labels in the kit's type style. These are
 * the clean, artifact-free controls — buttons with idle/pressed states, a D-pad with per-direction
 * states, a socket + separable ball for the analog stick, and the START/SELECT pill. The case body
 * and the square screen are produced separately by tools/gen_gb_ui_assets.js.
 *
 * Usage (needs Playwright + a Chromium build):
 *   PW=/path/to/playwright CHROME=/path/to/chrome node tools/gen_gb_ui_kit.js
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const KIT = path.join(ROOT, 'tools', 'gb_ui_kit');
const OUT = path.join(ROOT, 'sprites', 'gb_ui');
const SS = 4; // supersample factor

function loadPlaywright() {
  for (const c of [process.env.PW, '/opt/node22/lib/node_modules/playwright/index.js', 'playwright'].filter(Boolean)) {
    try { return require(c); } catch (e) {}
  }
  throw new Error('playwright not found; set PW=/abs/path/to/playwright/index.js');
}
function chromePath() {
  for (const c of [process.env.CHROME, '/opt/pw-browsers/chromium-1194/chrome-linux/chrome'].filter(Boolean)) {
    try { if (fs.statSync(c).isFile()) return c; } catch (e) {}
  }
  return undefined;
}
function nativeSize(svgPath) {
  const m = fs.readFileSync(svgPath, 'utf8').match(/viewBox="0 0 (\d+(?:\.\d+)?) (\d+(?:\.\d+)?)"/);
  return m ? { w: Math.round(+m[1]), h: Math.round(+m[2]) } : { w: 100, h: 100 };
}

// src svg name -> out png name
const CONTROLS = [];
for (const l of ['a', 'b', 'c', 'x', 'y', 'z']) {
  CONTROLS.push([`btn-${l}-idle`, `btn_${l.toUpperCase()}_idle`]);
  CONTROLS.push([`btn-${l}-pressed`, `btn_${l.toUpperCase()}_pressed`]);
}
for (const d of ['idle', 'up', 'down', 'left', 'right']) CONTROLS.push([`dpad-${d}`, `dpad_${d}`]);
CONTROLS.push(['pill-idle', 'pill_idle'], ['pill-pressed', 'pill_pressed']);
CONTROLS.push(['stick-pivot-idle', 'stick_pivot'], ['stick-ball-idle', 'stick_ball'], ['stick-ball-pressed', 'stick_ball_pressed']);

// Captions, in the kit's label style (see label-move.svg).
const WORDS = { move: 'MOVE', jump: 'JUMP', drive: 'DRIVE', hit: 'HIT', run: 'RUN', reset: 'RESET', use: 'USE', select: 'SELECT', start: 'START' };
const capSvg = (w) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 140 22" width="140" height="22"><text x="70" y="14" font-family="Arial, 'Helvetica Neue', Helvetica, sans-serif" font-size="12" letter-spacing="2.4" font-weight="600" text-anchor="middle" fill="#8B8678">${w}</text></svg>`;

(async () => {
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ executablePath: chromePath(), args: ['--no-sandbox', '--force-color-profile=srgb'] });
  const p = await browser.newPage({ deviceScaleFactor: SS });

  async function shoot(url, out, w, h) {
    await p.setViewportSize({ width: w, height: h });
    await p.goto(url, { waitUntil: 'load' });
    await p.waitForTimeout(30);
    await p.screenshot({ path: path.join(OUT, out + '.png'), omitBackground: true, clip: { x: 0, y: 0, width: w, height: h } });
  }

  for (const [src, out] of CONTROLS) {
    const file = path.join(KIT, src + '.svg');
    const { w, h } = nativeSize(file);
    await shoot('file://' + file, out, w, h);
  }

  const tmp = path.join(OUT, '_cap.svg');
  for (const [k, w] of Object.entries(WORDS)) {
    fs.writeFileSync(tmp, capSvg(w));
    await shoot('file://' + tmp, 'cap_' + k, 140, 22);
  }
  fs.unlinkSync(tmp);

  await browser.close();
  console.log('gb_ui kit: ' + CONTROLS.length + ' controls + ' + Object.keys(WORDS).length + ' captions -> ' + OUT);
})().catch((e) => { console.error(String(e).slice(0, 500)); process.exit(1); });
