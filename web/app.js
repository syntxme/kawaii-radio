// Kawaii Radio page: a showcase of the app (no music here) and the way into it.
(() => {
  'use strict';

  // ── pixel glyphs, the same ones the app draws (ui/kit/Icons.kt)
  const GLYPHS = {
    RADIO: ['.........##.', '.......##...', '.....##.....', '############', '#..........#', '#.####..##.#', '#.####.#..##', '#.####.#..##', '#.####..##.#', '#..........#', '############'],
    CHAT: ['.##########.', '############', '##........##', '##.##.##.###', '##........##', '############', '.##########.', '..###.......', '..##........', '..#.........'],
    STAR: ['.....##.....', '.....##.....', '....####....', '############', '.##########.', '..########..', '...######...', '..###..###..', '.##......##.'],
    DOWNLOAD: ['....##....', '....##....', '....##....', '....##....', '..######..', '...####...', '....##....', '..........', '##########', '##########'],
    HEART: ['.###...###.', '###########', '###########', '###########', '.#########.', '..#######..', '...#####...', '....###....', '.....#.....'],
  };
  function glyph(name) {
    const rows = GLYPHS[name] || [];
    const w = Math.max(...rows.map((r) => r.length));
    let rects = '';
    rows.forEach((r, y) => [...r].forEach((c, x) => { if (c === '#') rects += `<rect x="${x}" y="${y}" width="1.02" height="1.02"/>`; }));
    return `<svg viewBox="0 0 ${w} ${rows.length}" fill="currentColor" aria-hidden="true">${rects}</svg>`;
  }
  const drawGlyphs = (root = document) => root.querySelectorAll('.px[data-glyph]').forEach((el) => { el.innerHTML = glyph(el.dataset.glyph); });
  drawGlyphs();

  const $ = (id) => document.getElementById(id);

  // ── the station keys tell what each broadcast is
  const STATIONS = {
    jpop: { freq: 'J-POP FM', title: 'J-Pop', desc: "Yaponcha qo'shiqlar, anime opening va endinglari" },
    ost: { freq: 'OST FM', title: 'OST', desc: 'Saundtreklar: orkestr, pianino, Ghibli va anime kuylari' },
    riot: { freq: 'RIOT FM', title: 'Riot Music', desc: 'League of Legends, Valorant va Arcane musiqasi' },
  };
  document.querySelectorAll('.st').forEach((b) => b.addEventListener('click', () => {
    const s = STATIONS[b.dataset.st];
    document.querySelectorAll('.st').forEach((o) => { o.classList.toggle('on', o === b); o.setAttribute('aria-pressed', String(o === b)); });
    $('freq').textContent = s.freq;
    $('title').textContent = s.title;
    $('desc').textContent = s.desc;
  }));

  // ── a level meter on the LCD that never stops, like the radio in the app
  const SEGMENTS = 28;
  const bar = $('bar');
  bar.innerHTML = '<i></i>'.repeat(SEGMENTS);
  const segs = [...bar.children];
  let level = 0.6;
  const meter = () => {
    level = Math.min(0.95, Math.max(0.25, level + (Math.random() - 0.5) * 0.35));
    const lit = Math.round(level * SEGMENTS);
    segs.forEach((s, i) => s.classList.toggle('on', i < lit));
  };
  meter();
  if (!matchMedia('(prefers-reduced-motion: reduce)').matches) setInterval(meter, 180);

  // ── the app: on Android, open it when it is installed, otherwise the APK downloads
  const apk = new URL('/app/latest.apk', location.href).href;
  const ua = navigator.userAgent;
  if (/Android/i.test(ua)) {
    const open = $('open');
    open.href = `intent://p#Intent;scheme=kawaii;package=uz.kawaii.radio.kr01;S.browser_fallback_url=${encodeURIComponent(apk)};end`;
    $('openLabel').textContent = 'ILOVANI OCHISH';
    $('openSub').textContent = "O'rnatilmagan bo'lsa, yuklab olinadi";
    open.querySelector('.px').dataset.glyph = 'RADIO';
    drawGlyphs(open);
  } else if (/iPhone|iPad|iPod/i.test(ua)) {
    $('note').textContent = 'Hozircha ilova faqat Android uchun.';
  } else {
    $('note').textContent = 'Ilova Android uchun: shu sahifani telefoningizda oching.';
  }
})();
