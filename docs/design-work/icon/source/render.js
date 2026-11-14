// Render check sheets for the Benji icon set with Playwright Chromium.
// Run from anywhere:  node docs/design-work/icon/source/render.js
// Reads the SVGs in docs/design-work/icon/, writes PNG sheets to docs/design-work/icon/renders/.
// Every bitmap is rasterised from the vector at its target pixel size (like actool / NSImage
// would), then shown 1:1; zoom panels are nearest-neighbour blow-ups of those same pixels.
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const ICON = path.resolve(__dirname, '..');
const OUT = path.join(ICON, 'renders');
fs.mkdirSync(OUT, { recursive: true });

const uri = (rel) =>
  'data:image/svg+xml;base64,' + fs.readFileSync(path.join(ICON, rel)).toString('base64');

const icons = {
  default: uri('benji-app-icon.svg'),
  dark: uri('benji-app-icon-dark.svg'),
  tinted: uri('benji-app-icon-tinted.svg'),
  clear: uri('benji-app-icon-clear.svg'),
};
// Menu-bar glyphs: idle (the two elbows) and working (the halves closed). The first is the one
// the contact sheet and the ladder rows use.
const glyphFiles = process.argv.slice(2).length
  ? process.argv.slice(2)
  : ['benji-menubar-glyph.svg', 'benji-menubar-glyph-working.svg'];
const glyphs = glyphFiles.map((f) => ({ name: path.basename(f, '.svg').replace('benji-menubar-glyph', 'glyph').replace(/^glyph$/, 'glyph-idle') || f, src: uri(f) }));

// A neutral continuous-corner squircle on the same 824/1024 grid, for Dock placeholders.
const squircle = fs.readFileSync(path.join(ICON, 'benji-app-icon.svg'), 'utf8')
  .match(/<path d="(M[^"]+)" fill="url\(#t\)"\/>/)[1];
const placeholder = (fill, inner) =>
  'data:image/svg+xml;base64,' + Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><path d="${squircle}" fill="${fill}"/>` +
    (inner ? `<path d="${squircle}" fill="${inner}" transform="translate(512 512) scale(0.42) translate(-512 -512)"/>` : '') +
    '</svg>').toString('base64');
const placeholders = {
  light: [placeholder('#ffffff', '#d9dde1'), placeholder('#8e9aa6', '#c9d1d8'), placeholder('#e9e4dc', '#b9b1a4'),
          placeholder('#4a5560', '#7d8893'), placeholder('#d4d7db', '#ffffff')],
};

const page_html = `<!doctype html><meta charset="utf-8"><style>
  body{margin:0;background:#fff;font:13px/1.3 -apple-system,"SF Pro Text","Helvetica Neue",Arial,sans-serif;color:#222}
  .sheet{display:inline-block;padding:24px;background:#fff}
  h1{font-size:18px;margin:0 0 4px} p.note{margin:0 0 16px;color:#555;max-width:1100px}
  .row{display:flex;align-items:flex-end;gap:20px;padding:16px;border-radius:12px;margin-bottom:12px}
  .cell{display:flex;flex-direction:column;align-items:center;gap:6px}
  .lab{font-size:11px;color:inherit;opacity:.7;white-space:nowrap}
  .rowlab{width:92px;font-weight:600;align-self:center}
  canvas{display:block}
</style><body><div id="root"></div></body>`;

async function main() {
  const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH || undefined });
  const page = await browser.newPage({ viewport: { width: 2300, height: 1000 }, deviceScaleFactor: 1 });
  await page.setContent(page_html);
  await page.evaluate(({ icons, glyphs, placeholders }) => {
    window.ICONS = icons; window.GLYPHS = glyphs; window.PH = placeholders;
    const cache = {};
    window.load = (src) => cache[src] || (cache[src] = new Promise((res, rej) => {
      const i = new Image(); i.onload = () => res(i); i.onerror = rej; i.src = src;
    }));
    // rasterise an SVG at an exact pixel size; optional template ink (alpha only, like NSImage templates)
    window.raster = async (src, w, h, ink) => {
      const img = await load(src);
      const c = document.createElement('canvas'); c.width = w; c.height = h || w;
      const g = c.getContext('2d'); g.drawImage(img, 0, 0, w, h || w);
      if (ink) { g.globalCompositeOperation = 'source-in'; g.fillStyle = ink; g.fillRect(0, 0, w, h || w); }
      return c;
    };
    window.zoom = (src, k, bg) => {
      const c = document.createElement('canvas'); c.width = src.width * k; c.height = src.height * k;
      const g = c.getContext('2d'); g.imageSmoothingEnabled = false;
      if (bg) { g.fillStyle = bg; g.fillRect(0, 0, c.width, c.height); }
      g.drawImage(src, 0, 0, c.width, c.height); return c;
    };
    window.el = (tag, attrs = {}, ...kids) => {
      const e = document.createElement(tag); Object.assign(e, attrs);
      if (attrs.style) e.setAttribute('style', attrs.style);
      kids.flat().forEach((k) => e.append(k)); return e;
    };
    window.cell = (canvas, label) => el('div', { className: 'cell' }, canvas, el('div', { className: 'lab', textContent: label }));
  }, { icons, glyphs, placeholders });

  const shot = async (name, build) => {
    await page.evaluate(() => { document.getElementById('root').innerHTML = ''; });
    await page.evaluate(build);
    const box = await page.$('#root > .sheet');
    await box.screenshot({ path: path.join(OUT, name) });
    console.log('wrote renders/' + name);
  };

  // 1. app icon, each appearance at 1024 (2 x 2 grid)
  await shot('app-icon-1024.png', async () => {
    const bg = { default: '#e9e9ec', dark: '#1d1d1f', tinted: '#2b2b2e', clear: 'linear-gradient(135deg,#6f8fa0,#b7a58f)' };
    const s = el('div', { className: 'sheet', style: 'display:inline-grid;grid-template-columns:repeat(2,1088px);gap:8px;padding:8px' });
    for (const k of ['default', 'dark', 'tinted', 'clear']) {
      const c = await raster(ICONS[k], 1024);
      s.append(el('div', { style: `background:${bg[k]};padding:32px;border-radius:12px;position:relative` }, c,
        el('div', { textContent: k + ' · 1024 px', style: `position:absolute;left:44px;top:40px;font:600 22px sans-serif;color:${k === 'default' ? '#333' : '#eee'}` })));
    }
    document.getElementById('root').append(s);
  });

  // 2. app icon sizes 512 .. 16 per appearance, plus 8x zooms of 32 and 16
  await shot('app-icon-sizes.png', async () => {
    const s = el('div', { className: 'sheet' },
      el('h1', { textContent: 'Benji app icon · 512, 256, 128, 64, 32, 16 px (1:1) and 8× zooms of 32 and 16' }),
      el('p', { className: 'note', textContent: 'Each bitmap is rasterised from the SVG at that pixel size. Default on a light ground, dark/tinted on dark, clear over a coloured ground (it needs something behind it).' }));
    const bg = { default: ['#ececef', '#222'], dark: ['#1d1d1f', '#eee'], tinted: ['#2b2b2e', '#eee'], clear: ['linear-gradient(135deg,#6f8fa0,#b7a58f)', '#fff'] };
    for (const k of ['default', 'dark', 'tinted', 'clear']) {
      const row = el('div', { className: 'row', style: `background:${bg[k][0]};color:${bg[k][1]}` }, el('div', { className: 'rowlab', textContent: k }));
      for (const px of [512, 256, 128, 64, 32, 16]) row.append(cell(await raster(ICONS[k], px), px + ' px'));
      const flat = bg[k][0].startsWith('#') ? bg[k][0] : '#8f9a98';
      row.append(cell(zoom(await raster(ICONS[k], 32), 8, flat), '32 px ×8'));
      row.append(cell(zoom(await raster(ICONS[k], 16), 8, flat), '16 px ×8'));
      s.append(row);
    }
    document.getElementById('root').append(s);
  });

  // 3. Dock-like strips (Retina: 64 pt tiles = 128 px) beside neutral placeholder squircles
  await shot('dock-strips.png', async () => {
    const s = el('div', { className: 'sheet' },
      el('h1', { textContent: 'Dock check · 128 px (64 pt @2x) and 64 px (64 pt @1x), beside neutral placeholder squircles' }),
      el('p', { className: 'note', textContent: 'Placeholders are plain squircles on the same grid, not Apple icons. Light desktop uses the default appearance, dark desktop the dark one; tinted and clear are shown on their own strips.' }));
    const strips = [
      ['light desktop · default', 'linear-gradient(160deg,#dfe7ee,#c9d3dc 60%,#e8e1d6)', 'rgba(255,255,255,.45)', 'default', false],
      ['dark desktop · dark', 'linear-gradient(160deg,#1b2430,#0f1216 60%,#2a2320)', 'rgba(40,40,44,.55)', 'dark', false],
      ['dark desktop · tinted', 'linear-gradient(160deg,#1b2430,#0f1216 60%,#2a2320)', 'rgba(40,40,44,.55)', 'tinted', true],
      ['light desktop · clear', 'linear-gradient(160deg,#9db4c4,#c7b9a3 60%,#a6b7a0)', 'rgba(255,255,255,.35)', 'clear', true],
    ];
    for (const [label, desk, dock, key, gray] of strips) {
      for (const px of [128, 64]) {
        const bar = el('div', { style: `display:flex;gap:${px / 8}px;padding:${px / 10}px ${px / 5}px;background:${dock};border-radius:${px / 3.5}px;border:1px solid rgba(255,255,255,.35);backdrop-filter:blur(20px)` });
        const ph = PH.light.map((p) => p);
        const order = [ph[0], ph[1], 'ICON', ph[2], ph[3], ph[4]];
        for (const o of order) {
          const c = await raster(o === 'ICON' ? ICONS[key] : o, px);
          if (gray && o !== 'ICON') c.style.filter = key === 'clear' ? 'grayscale(1) opacity(.55) brightness(1.4)' : 'grayscale(1) brightness(.55)';
          bar.append(c);
        }
        s.append(el('div', { style: `background:${desk};padding:${px / 3}px ${px / 2}px;border-radius:12px;margin-bottom:10px;display:flex;align-items:center;gap:24px` },
          el('div', { textContent: `${label} · ${px} px`, style: `font-weight:600;width:170px;color:${label.startsWith('dark') ? '#eee' : '#223'}` }), bar));
      }
    }
    document.getElementById('root').append(s);
  });

  // 4. menu-bar glyphs: 16/18/22/32 px at 1x and the 18 pt glyph at 2x, light + dark bars
  await shot('menubar-glyphs.png', async () => {
    const s = el('div', { className: 'sheet' },
      el('h1', { textContent: 'Menu-bar glyph · template image tinted like macOS (alpha only) · 16, 18, 22, 32 px at 1×, 18 pt and 22 pt at 2× · 8× zooms of 16 and 18 px' }),
      el('p', { className: 'note', textContent: 'Light bar ink: black 85%. Dark bar ink: white. Menu-bar text at 13 px is shown for weight. Bar height 24 px (notch Macs: 24 pt+).' }));
    const bars = [['light', 'rgba(246,246,246,1)', 'rgba(0,0,0,.85)', '#000'], ['dark', '#26282b', '#ffffff', '#fff']];
    for (const g of GLYPHS) {
      for (const [mode, bg, ink, txt] of bars) {
        const row = el('div', { className: 'row', style: `background:${bg};color:${txt};align-items:center;border-radius:6px;padding:8px 16px` },
          el('div', { className: 'rowlab', textContent: g.name + ' · ' + mode, style: 'width:150px;font-size:12px' }));
        for (const px of [16, 18, 22, 32]) row.append(cell(await raster(g.src, px, px, ink), px + ''));
        for (const pt of [18, 22]) row.append(cell(await raster(g.src, pt * 2, pt * 2, ink), pt + 'pt@2x'));
        const z = async (px) => { const c = await raster(g.src, px, px, ink); return zoom(c, 8, mode === 'light' ? '#f6f6f6' : '#26282b'); };
        row.append(cell(await z(16), '16 ×8'));
        row.append(cell(await z(18), '18 ×8'));
        row.append(el('div', { textContent: 'Mon 2 Nov  9:41', style: `font:13px -apple-system,"Helvetica Neue",Arial,sans-serif;color:${ink}` }));
        s.append(row);
      }
    }
    // Retina reality: a 24 pt menu bar drawn at 2x (48 px), menu-bar text at 13 pt (26 px)
    s.append(el('h1', { textContent: 'Retina mock · 24 pt bar at @2x, 13 pt text at @2x, glyph 18 pt (36 px)', style: 'margin-top:16px' }));
    for (const [mode, bg, ink] of bars) {
      const bar = el('div', { style: `background:${bg};height:48px;display:flex;align-items:center;justify-content:flex-end;gap:28px;padding:0 24px;border-radius:6px;margin-bottom:8px;font:26px -apple-system,"Helvetica Neue",Arial,sans-serif;color:${ink}` });
      for (const g of GLYPHS) bar.append(await raster(g.src, 36, 36, ink));
      bar.append(el('span', { textContent: 'Mon 2 Nov  9:41' }));
      s.append(bar);
    }
    document.getElementById('root').append(s);
  });

  // 4b. both menu-bar glyphs at 4x (18 pt = 72 px), idle beside working, on light and dark bars
  await shot('menubar-glyphs-4x.png', async () => {
    const s = el('div', { className: 'sheet' },
      el('h1', { textContent: 'Menu-bar glyphs at 4× (18 pt box = 72 px) · idle, then working · template ink on light and dark bars' }));
    for (const [mode, bg, ink] of [['light', '#f6f6f6', 'rgba(0,0,0,.85)'], ['dark', '#26282b', '#ffffff']]) {
      const row = el('div', { className: 'row', style: `background:${bg};color:${ink};gap:48px;padding:24px 32px` },
        el('div', { className: 'rowlab', textContent: mode }));
      for (const g of GLYPHS) row.append(cell(await raster(g.src, 72, 72, ink), g.name));
      s.append(row);
    }
    document.getElementById('root').append(s);
  });

  // 5. contact sheet: the final set at a glance
  await shot('contact-sheet.png', async () => {
    const s = el('div', { className: 'sheet', style: 'width:1180px' },
      el('h1', { textContent: 'Benji · Exchange · final icon set (D-137)' }),
      el('p', { className: 'note', textContent: 'Flat SVG previews of the four appearances at 256 px, the size ladder, the Dock at 64 pt @2x, and the menu-bar glyph as a template image. The real Liquid Glass rendering comes from Icon Composer (unverified here).' }));
    const top = el('div', { style: 'display:flex;gap:12px;margin-bottom:12px' });
    const bg = { default: ['#ececef', '#222'], dark: ['#1d1d1f', '#eee'], tinted: ['#2b2b2e', '#eee'], clear: ['linear-gradient(135deg,#6f8fa0,#b7a58f)', '#fff'] };
    for (const k of ['default', 'dark', 'tinted', 'clear']) {
      top.append(el('div', { style: `background:${bg[k][0]};color:${bg[k][1]};padding:14px;border-radius:12px` },
        cell(await raster(ICONS[k], 256), k)));
    }
    s.append(top);
    const ladder = el('div', { className: 'row', style: 'background:#ececef' }, el('div', { className: 'rowlab', textContent: 'default' }));
    const ladderD = el('div', { className: 'row', style: 'background:#1d1d1f;color:#eee' }, el('div', { className: 'rowlab', textContent: 'dark' }));
    for (const px of [128, 64, 32, 16]) { ladder.append(cell(await raster(ICONS.default, px), px + ' px')); ladderD.append(cell(await raster(ICONS.dark, px), px + ' px')); }
    const g = GLYPHS[0];
    for (const [r, ink] of [[ladder, 'rgba(0,0,0,.85)'], [ladderD, '#fff']]) {
      r.append(el('div', { style: 'width:40px' }));
      r.append(el('div', { className: 'rowlab', textContent: 'menu bar', style: 'width:70px' }));
      for (const px of [16, 18, 22]) r.append(cell(await raster(g.src, px, px, ink), px + ' px'));
      r.append(cell(await raster(g.src, 36, 36, ink), '18 pt@2x'));
    }
    s.append(ladder, ladderD);
    for (const [desk, dock, key] of [['linear-gradient(160deg,#dfe7ee,#c9d3dc 60%,#e8e1d6)', 'rgba(255,255,255,.45)', 'default'], ['linear-gradient(160deg,#1b2430,#0f1216 60%,#2a2320)', 'rgba(40,40,44,.55)', 'dark']]) {
      const bar = el('div', { style: `display:flex;gap:12px;padding:10px 20px;background:${dock};border-radius:30px;border:1px solid rgba(255,255,255,.35)` });
      for (const o of [PH.light[0], PH.light[1], 'ICON', PH.light[2], PH.light[3], PH.light[4]]) bar.append(await raster(o === 'ICON' ? ICONS[key] : o, 96));
      s.append(el('div', { style: `background:${desk};padding:24px;border-radius:12px;margin-bottom:10px;display:flex;justify-content:center` }, bar));
    }
    document.getElementById('root').append(s);
  });

  await browser.close();
}
main().catch((e) => { console.error(e); process.exit(1); });
