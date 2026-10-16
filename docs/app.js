/* CinemaMax Website – ohne Bibliotheken, damit sie auch auf Fernsehern schnell lädt. */
(() => {
  'use strict';
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const root = document.documentElement;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const store = {
    get: (k) => { try { return localStorage.getItem(k); } catch (_) { return null; } },
    set: (k, v) => { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch (_) {} },
  };

  /* ================= Hell / Dunkel ================= */
  const sysDark = matchMedia('(prefers-color-scheme: dark)');
  const sw = $('#themeSwitch');
  const mode = () => root.dataset.theme || (sysDark.matches ? 'dark' : 'light');
  function paintSwitch() {
    const m = mode();
    root.dataset.mode = m;
    sw.setAttribute('aria-checked', String(m === 'light'));
    sw.setAttribute('aria-label', m === 'light' ? 'Dunklen Modus einschalten' : 'Hellen Modus einschalten');
    $$('meta[name="theme-color"]').forEach((t) => t.setAttribute('content', m === 'light' ? '#F5F5F7' : '#0A0A0B'));
  }
  function setTheme(next) {
    // Gleich wie das System: Wahl vergessen, damit die Seite wieder dem System folgt
    if (next === (sysDark.matches ? 'dark' : 'light')) { delete root.dataset.theme; store.set('theme', null); }
    else { root.dataset.theme = next; store.set('theme', next); }
    paintSwitch();
  }
  sw.addEventListener('click', () => {
    const next = mode() === 'dark' ? 'light' : 'dark';
    const r = sw.getBoundingClientRect();
    root.style.setProperty('--vt-x', `${r.left + r.width / 2}px`);
    root.style.setProperty('--vt-y', `${r.top + r.height / 2}px`);
    if (document.startViewTransition && !reduced) document.startViewTransition(() => setTheme(next));
    else setTheme(next);
  });
  sysDark.addEventListener('change', paintSwitch);
  paintSwitch();

  /* ================= Akzentfarbe ================= */
  function onAccentFor(hex) {
    const n = parseInt(hex.slice(1), 16);
    const lin = (v) => { v /= 255; return v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; };
    const L = .2126 * lin(n >> 16 & 255) + .7152 * lin(n >> 8 & 255) + .0722 * lin(n & 255);
    return L > .36 ? '#000' : '#fff';
  }
  function setAccent(hex, save = true) {
    root.style.setProperty('--accent', hex);
    root.style.setProperty('--on-accent', onAccentFor(hex));
    $$('.swatch[data-color]').forEach((s) => s.setAttribute('aria-checked', String(s.dataset.color.toLowerCase() === hex.toLowerCase())));
    $('#customColor').value = hex;
    if (save) store.set('accent', hex);
  }
  setAccent(store.get('accent') || '#3E8BFF', false);
  $$('.swatch[data-color]').forEach((s) => s.addEventListener('click', () => setAccent(s.dataset.color)));
  $('#customColor').addEventListener('input', (e) => setAccent(e.target.value));

  // Nach dem Intro: keine Verzögerung mehr beim Einblenden
  setTimeout(() => root.classList.add('ready'), reduced ? 0 : 1900);

  /* ================= Navigation oben ================= */
  const nav = $('.nav');
  const onScroll = () => nav.classList.toggle('scrolled', scrollY > 10);
  addEventListener('scroll', onScroll, { passive: true });
  onScroll();
  const links = $$('.nav-links a');
  const sectionObs = new IntersectionObserver((es) => es.forEach((e) => {
    if (e.isIntersecting) links.forEach((a) => a.classList.toggle('active', a.getAttribute('href') === `#${e.target.id}`));
  }), { rootMargin: '-45% 0px -50% 0px' });
  ['features', 'how', 'remote', 'download', 'faq'].forEach((id) => sectionObs.observe(document.getElementById(id)));

  /* ================= Einblenden & Zähler ================= */
  const revealObs = new IntersectionObserver((es) => es.forEach((e) => {
    if (!e.isIntersecting) return;
    e.target.classList.add('in');
    revealObs.unobserve(e.target);
    const b = e.target.querySelector('[data-count]');
    if (b) count(b);
  }), { rootMargin: '0px 0px -8% 0px', threshold: .08 });
  $$('.reveal').forEach((el) => revealObs.observe(el));
  function count(b) {
    const to = +b.dataset.count, t0 = performance.now(), dur = 900;
    const step = (t) => {
      const p = Math.min(1, (t - t0) / dur);
      b.textContent = Math.round(to * (1 - (1 - p) ** 3));
      if (p < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  /* Karten neigen sich leicht zur Maus */
  if (matchMedia('(hover: hover) and (pointer: fine)').matches && !reduced) {
    $$('.card').forEach((c) => {
      c.addEventListener('pointermove', (e) => {
        if (!c.classList.contains('in')) return;
        const r = c.getBoundingClientRect();
        const x = (e.clientX - r.left) / r.width - .5, y = (e.clientY - r.top) / r.height - .5;
        c.style.transform = `perspective(900px) rotateX(${-y * 4}deg) rotateY(${x * 5}deg) translateY(-3px)`;
      });
      c.addEventListener('pointerleave', () => { c.style.transform = ''; });
    });
  }

  /* ================= Startton ================= */
  const soundBtn = $('#soundBtn');
  const audio = new Audio();
  if (!audio.canPlayType('audio/ogg')) soundBtn.hidden = true;
  soundBtn.addEventListener('click', () => {
    audio.src = 'assets/intro.ogg';
    audio.currentTime = 0;
    audio.play().then(() => {
      soundBtn.classList.add('playing');
      replayIntro();
    }).catch(() => {});
  });
  audio.addEventListener('ended', () => soundBtn.classList.remove('playing'));
  function replayIntro() {
    const intro = $('.intro');
    const clone = intro.cloneNode(true);
    intro.replaceWith(clone);
  }

  /* ================= Gerät erkennen & Downloads ================= */
  const ua = navigator.userAgent;
  const isTv = root.classList.contains('tv');
  const os = /Android/i.test(ua) || isTv ? 'android' : /Windows/i.test(ua) ? 'windows' : /Linux|X11|CrOS/i.test(ua) ? 'linux' : null;
  const names = { android: isTv ? 'Android TV' : 'Android', windows: 'Windows', linux: 'Linux' };
  if (os) {
    $(`.platform[data-os="${os}"]`).classList.add('mine');
    $('#heroDownloadText').textContent = `Für ${names[os]} herunterladen`;
    $('#osHint').textContent = `Erkannt: ${names[os]} · auch für ${Object.values(names).filter((n) => n !== names[os] && !(os === 'android' && n.startsWith('Android'))).join(', ')}`;
  }
  const assetFor = { apk: /\.apk$/i, windows: /windows.*setup\.exe$/i, appimage: /\.AppImage$/i, deb: /\.deb$/i, rpm: /\.rpm$/i };
  const osAsset = { android: 'apk', windows: 'windows' };
  fetch('https://api.github.com/repos/Emre1001/CinemaMax/releases/latest', { headers: { Accept: 'application/vnd.github+json' } })
    .then((r) => (r.ok ? r.json() : Promise.reject()))
    .then((rel) => {
      $$('[data-asset]').forEach((a) => {
        const m = rel.assets.find((x) => assetFor[a.dataset.asset].test(x.name));
        if (m) a.href = m.browser_download_url;
      });
      const span = $('.platform[data-os="android"] span');
      if (span && rel.tag_name) span.textContent = `APK · ${rel.tag_name} · Android 7 oder neuer`;
      if (os) {
        const m = osAsset[os] && rel.assets.find((x) => assetFor[osAsset[os]].test(x.name));
        if (m) $('#heroDownload').href = m.browser_download_url;
      }
    })
    .catch(() => {/* bleibt bei der Release-Seite */});

  /* Linux: Paketformat wählen lassen (Distribution aus dem Browser erraten, falls möglich) */
  const linuxDialog = $('#linuxDialog');
  const guess = /Ubuntu|Debian|Mint|Pop!?_OS|elementary|Zorin/i.test(ua) ? 'deb' : /Fedora|Red Hat|openSUSE|SUSE|CentOS|Rocky/i.test(ua) ? 'rpm' : 'appimage';
  $$('.ld-opt').forEach((o) => o.classList.toggle('rec', o.dataset.fmt === guess));
  function chooseLinux(e) {
    e.preventDefault();
    linuxDialog.showModal();
    $(`.ld-opt[data-fmt="${guess}"]`).focus();
  }
  $$('[data-linux-choose]').forEach((a) => a.addEventListener('click', chooseLinux));
  if (os === 'linux') $('#heroDownload').addEventListener('click', chooseLinux);
  linuxDialog.addEventListener('click', (e) => { if (e.target === linuxDialog) linuxDialog.close(); });
  $$('.ld-opt').forEach((o) => o.addEventListener('click', () => setTimeout(() => linuxDialog.close(), 300)));

  /* ================= So geht's ================= */
  const steps = $$('.step'), stages = $$('.stage'), stepsEl = $('#steps');
  let stepIdx = 0, stepTimer = null, stepVisible = false;
  function showStep(i) {
    stepIdx = i;
    steps.forEach((s, k) => s.classList.toggle('is-active', k === i));
    stages.forEach((s, k) => s.classList.toggle('is-active', k === i));
    stepsEl.style.setProperty('--progress', i / (steps.length - 1));
    if (i === 0) typeForm(currentForm);
  }
  function autoSteps() {
    clearInterval(stepTimer);
    if (stepVisible && !reduced) stepTimer = setInterval(() => showStep((stepIdx + 1) % steps.length), 5200);
  }
  steps.forEach((s, i) => s.querySelector('button').addEventListener('click', () => { showStep(i); autoSteps(); }));
  new IntersectionObserver(([e]) => { stepVisible = e.isIntersecting; if (stepVisible) showStep(stepIdx); autoSteps(); }, { threshold: .35 }).observe($('#how'));

  const forms = {
    xtream: [['Name', 'Mein Server'], ['Server-URL', 'http://iptv.example.net:8080'], ['Benutzername', 'max'], ['Passwort', '••••••••']],
    m3u: [['Name', 'Meine Liste'], ['M3U-URL', 'https://example.net/playlist.m3u8']],
    stalker: [['Name', 'Portal'], ['Portal-URL', 'http://portal.example.net/c/'], ['MAC-Adresse', '00:1A:79:4B:2C:9F']],
  };
  let currentForm = 'xtream', typeTimer = null;
  function typeForm(kind) {
    currentForm = kind;
    $$('.form-tabs button').forEach((b) => b.setAttribute('aria-selected', String(b.dataset.form === kind)));
    const box = $('#formFields');
    box.innerHTML = forms[kind].map(([l], i) => `<div class="field" style="animation-delay:${i * 60}ms"><label>${l}</label><span></span></div>`).join('');
    clearTimeout(typeTimer);
    const spans = $$('span', box);
    let f = 0, c = 0;
    const tick = () => {
      if (f >= spans.length) return;
      const text = forms[kind][f][1];
      spans.forEach((s, k) => s.style.setProperty('--caret', k === f ? 1 : 0));
      spans[f].textContent = text.slice(0, ++c);
      if (c >= text.length) { f++; c = 0; }
      typeTimer = setTimeout(tick, reduced ? 0 : c === 0 ? 220 : 34);
    };
    tick();
  }
  $$('.form-tabs button').forEach((b) => b.addEventListener('click', () => { typeForm(b.dataset.form); autoSteps(); }));
  $$('.sort-in span').forEach((s, i) => s.style.setProperty('--i', i));

  /* ================= Fernbedienung ================= */
  const keyInfo = {
    up: ['Pfeil hoch', 'Nach oben. Im Player: Sender wechseln.', 'Im Live-Player springst du mit Hoch und Runter durch die Sender, ohne das Bild anzuhalten.'],
    down: ['Pfeil runter', 'Nach unten. Im Player: nächster Sender.', 'Die Richtung lässt sich in den Einstellungen umdrehen, falls du es andersherum gewohnt bist.'],
    left: ['Pfeil links', 'Zur Seitenleiste. Im Player: Senderliste oder zurückspulen.', 'Bei Filmen spult Links um 10 Sekunden zurück, bei Live-Sendern öffnet es die Senderliste.'],
    right: ['Pfeil rechts', 'Zum Inhalt. Im Player: vorspulen.', 'Der Spulschritt ist einstellbar: 5, 10, 15, 30 oder 60 Sekunden.'],
    ok: ['OK', 'Öffnen und abspielen. Lange drücken: Favorit.', 'Kurz drücken öffnet, lange drücken speichert Sender, Filme und Serien in deinen Favoriten.'],
    back: ['Zurück', 'Bedienleiste ausblenden, dann eine Ebene zurück.', 'Auf dem Fernseher springt Zurück zuerst in die Seitenleiste, damit du dich nie verirrst.'],
    menu: ['Menü', 'Optionen für Sender, Server und Favoriten.', 'Im Player öffnet die Menütaste die Senderliste mit allen Sendern der aktuellen Kategorie.'],
    num: ['Zifferntasten', 'Sendernummer eintippen, wie beim Fernseher.', 'Tipp 1, 2, dann warte kurz: CinemaMax schaltet auf Sender 12.'],
  };
  function showKey(k) {
    const [key, title, text] = keyInfo[k];
    $$('.rk').forEach((b) => b.classList.toggle('on', b.dataset.key === k));
    const info = $('.remote-info');
    $('#rkKey').textContent = key;
    $('#rkTitle').textContent = title;
    $('#rkText').textContent = text;
    info.classList.remove('rk-flash'); void info.offsetWidth; info.classList.add('rk-flash');
  }
  $$('.rk').forEach((b) => {
    b.addEventListener('click', () => showKey(b.dataset.key));
    b.addEventListener('focus', () => showKey(b.dataset.key));
  });

  /* ================= App-Vorschau ================= */
  const channels = [
    ['Nordlicht 1', 'N1', '#3E8BFF', 'Vollprogramm', 'Der lange Weg', .42],
    ['Kanal Süd', 'KS', '#E5484D', 'Vollprogramm', 'Heimatabend', .67],
    ['Arena Sport', 'AS', '#30A46C', 'Sport', 'Fußball live', .18],
    ['Sport Zwei', 'S2', '#14B8A6', 'Sport', 'Motorsport Magazin', .81],
    ['Info 24', 'i24', '#E5A23A', 'Nachrichten', 'Nachrichten am Abend', .55],
    ['Welt Aktuell', 'WA', '#8E4EC6', 'Nachrichten', 'Der Tag', .3],
    ['Doku One', 'D1', '#E93D82', 'Dokumentation', 'Tiefsee', .72],
    ['Planet Wild', 'PW', '#30A46C', 'Dokumentation', 'Die Savanne', .12],
    ['Kino Klassik', 'KK', '#E5A23A', 'Filme', 'Schwarzweiß-Nacht', .48],
    ['Serien Max', 'SM', '#3E8BFF', 'Filme', 'Funkstille S02E04', .9],
    ['Kids Club', 'KC', '#FFB547', 'Kinder', 'Die Bücherbande', .35],
    ['Musik Box', 'MB', '#E93D82', 'Musik', 'Top 40 Countdown', .6],
    ['Radio Nord', 'RN', '#14B8A6', 'Musik', 'Nachtfrequenz', .2],
    ['Regional TV', 'RT', '#8E8E96', 'Vollprogramm', 'Stadtgespräch', .77],
  ];
  const movies = [
    ['Neonstadt', 2024, '7.8', '#1E3A8A', '#9333EA'], ['Kodex', 2023, '7.1', '#111827', '#DC2626'], ['Stille Wasser', 2022, '7.4', '#0F766E', '#1E3A8A'],
    ['Nachtfahrt', 2024, '6.9', '#312E81', '#F59E0B'], ['Die Insel', 2021, '7.6', '#065F46', '#FDE68A'], ['Gegenwind', 2023, '6.8', '#7C2D12', '#FB923C'],
    ['Sommerhaus', 2022, '7.0', '#BE185D', '#FDBA74'], ['Funklicht', 2024, '7.3', '#0C4A6E', '#22D3EE'], ['Grenzland', 2020, '7.9', '#1F2937', '#A3A3A3'],
    ['Der Zeuge', 2023, '7.2', '#3F1D38', '#E879F9'], ['Asche', 2021, '6.6', '#27272A', '#F97316'], ['Weite', 2024, '8.1', '#1E40AF', '#93C5FD'],
  ];
  const series = [
    ['Nachtzug', '3 Staffeln', '8.2', '#0B132B', '#5BC0BE'], ['Funkstille', '2 Staffeln', '7.9', '#22223B', '#C9ADA7'], ['Hafen 9', '4 Staffeln', '7.5', '#003049', '#F77F00'],
    ['Die Akte', '1 Staffel', '7.7', '#2B2D42', '#EF233C'], ['Zwielicht', '2 Staffeln', '8.0', '#14213D', '#FCA311'], ['Grünes Tal', '5 Staffeln', '7.2', '#283618', '#DDA15E'],
    ['Signal', '3 Staffeln', '8.4', '#001219', '#0A9396'], ['Ostwind', '2 Staffeln', '7.1', '#3D0E61', '#F2A65A'],
  ];

  const device = $('#device'), screen = $('#screen'), body = $('#dBody'), title = $('#dTitle');
  const player = $('#dPlayer');
  let tab = 'live', cat = 'Alle', playing = null, zapList = channels, osdTimer = null, paused = false;
  const tabTitles = { search: 'Suche', home: 'Start', live: 'Live TV', guide: 'TV-Guide', movies: 'Filme', series: 'Serien' };
  const pad = (n) => String(n).padStart(2, '0');
  const now = () => { const d = new Date(); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
  const clock = () => { $('#dClock').textContent = now(); $('#dOsdClock').textContent = now(); };
  clock(); setInterval(clock, 15000);

  const tile = (c, i) => `<button class="d-tile" data-ch="${channels.indexOf(c)}" style="--i:${i}"><span class="d-logo-mark" style="--c:${c[2]}">${c[1]}</span><b>${c[0]}</b><small>${c[4]}</small><span class="bar"><i style="--p:${c[5] * 100}%"></i></span></button>`;
  const poster = (m, i, kind) => `<button class="d-poster" data-${kind}="${(kind === 'movie' ? movies : series).indexOf(m)}" style="--i:${i}"><span class="d-poster-art" style="--a:${m[3]};--b:${m[4]}"><span>${m[0]}</span></span><b>${m[0]}</b><small>${m[1]} · ★ ${m[2]}</small></button>`;

  function render() {
    title.textContent = tabTitles[tab];
    $$('.d-tab').forEach((t) => t.setAttribute('aria-current', String(t.dataset.tab === tab)));
    let html = '';
    if (tab === 'live' || tab === 'movies' || tab === 'series') {
      const groups = tab === 'live' ? ['Alle', 'Favoriten', ...new Set(channels.map((c) => c[3]))] : ['Alle', 'Neu hinzugefügt', 'Action', 'Drama', 'Komödie', 'Thriller'];
      if (!groups.includes(cat)) cat = 'Alle';
      const list = tab === 'live' ? channels.filter((c) => cat === 'Alle' || c[3] === cat || (cat === 'Favoriten' && [0, 2, 6].includes(channels.indexOf(c)))) : (tab === 'movies' ? movies : series);
      if (tab === 'live') zapList = list;
      html = `<div class="d-cats">${groups.map((g, i) => `${i === 2 ? '<div class="d-cat-head">KATEGORIEN</div>' : ''}<button class="d-cat${g === cat ? ' sel' : ''}" data-cat="${g}"><span>${g}</span>${tab === 'live' && i > 1 ? `<i>${channels.filter((c) => c[3] === g).length}</i>` : ''}</button>`).join('')}</div>`;
      html += tab === 'live'
        ? `<div class="d-grid">${list.map(tile).join('')}</div>`
        : `<div class="d-grid posters">${list.map((m, i) => poster(m, i, tab === 'movies' ? 'movie' : 'series')).join('')}</div>`;
    } else if (tab === 'home') {
      html = `<div class="d-home"><button class="d-hero-card" data-movie="11"><div><span>Neu · Film · 2024</span><b>Weite</b></div><em>Abspielen</em></button>
        <div class="d-row-title">Weiterschauen</div><div class="d-row">${movies.slice(0, 6).map((m, i) => poster(m, i, 'movie')).join('')}</div>
        <div class="d-row-title">Zuletzt gesehene Sender</div><div class="d-row">${channels.slice(0, 6).map(tile).join('')}</div>
        <div class="d-row-title">Neu: Serien</div><div class="d-row">${series.map((m, i) => poster(m, i, 'series')).join('')}</div></div>`;
    } else if (tab === 'guide') {
      const sel = +(screen.dataset.guide || 0);
      const c = channels[sel];
      const progs = [['18:30', '19:15', 'Vorabend'], ['19:15', '20:00', 'Kurz gefragt'], ['20:00', '20:15', 'Nachrichten'], ['20:15', '21:45', c[4]], ['21:45', '22:30', 'Spätmagazin'], ['22:30', '00:05', 'Nachtkino']];
      html = `<div class="d-guide"><div class="d-guide-ch">${channels.map((x, i) => `<button class="${i === sel ? 'sel' : ''}" data-gch="${i}"><span class="mk" style="--c:${x[2]}">${x[1]}</span><span><b>${x[0]}</b><small>${x[4]}</small></span></button>`).join('')}</div>
        <div class="d-progs">${progs.map((p, i) => `<button class="d-prog ${i < 3 ? 'past' : i === 3 ? 'now' : ''}" data-ch="${sel}" style="--i:${i}"><time>${p[0]}–${p[1]}</time><span><b>${p[2]}</b><small>${i === 3 ? 'Läuft gerade · OK zum Einschalten' : i < 3 ? 'Rückschau verfügbar' : 'Demnächst'}</small></span></button>`).join('')}</div></div>`;
    } else if (tab === 'search') {
      html = `<div class="d-search"><div class="d-search-field"><svg viewBox="0 0 24 24"><path d="M10.5 4a6.5 6.5 0 015.2 10.4l4 4a1 1 0 01-1.4 1.4l-4-4A6.5 6.5 0 1110.5 4zm0 2a4.5 4.5 0 100 9 4.5 4.5 0 000-9z"/></svg><span id="dQuery"></span><span class="caret"></span></div>
        <div class="d-row-title">Live (2)</div><div class="d-row">${[channels[2], channels[3]].map(tile).join('')}</div>
        <div class="d-row-title">Filme (1)</div><div class="d-row">${poster(movies[7], 0, 'movie')}</div></div>`;
    }
    body.innerHTML = html;
    body.style.animation = 'none'; void body.offsetWidth; body.style.animation = '';
    if (tab === 'search') typeQuery('sport');
  }
  function typeQuery(q) {
    let i = 0;
    const el = $('#dQuery');
    const t = () => { if (!el.isConnected) return; el.textContent = q.slice(0, ++i); if (i < q.length) setTimeout(t, 140); };
    setTimeout(t, 300);
  }

  function openChannel(i) {
    const c = channels[i];
    playing = { kind: 'live', i };
    player.hidden = false;
    $('#dVideoTitle').textContent = c[0];
    $('#dOsdLogo').textContent = c[1];
    $('#dOsdLogo').style.setProperty('--c', c[2]);
    $('#dOsdName').textContent = `${zapList.indexOf(c) + 1}  ${c[0]}`;
    $('#dOsdNow').textContent = `20:15–21:45  ${c[4]}`;
    $('#dProgress').style.width = `${c[5] * 100}%`;
    const v = $('#dVideo');
    v.style.setProperty('--v1', c[2]);
    v.style.setProperty('--v2', channels[(i + 5) % channels.length][2]);
    showOsd();
    $('.d-btn-big').focus({ preventScroll: true });
  }
  function openTitle(m) {
    playing = { kind: 'vod' };
    player.hidden = false;
    $('#dVideoTitle').textContent = m[0];
    $('#dOsdLogo').textContent = '';
    $('#dOsdName').textContent = m[0];
    $('#dOsdNow').textContent = `${m[1]} · ★ ${m[2]}`;
    $('#dProgress').style.width = '12%';
    $('#dVideo').style.setProperty('--v1', m[3]);
    $('#dVideo').style.setProperty('--v2', m[4]);
    showOsd();
    $('.d-btn-big').focus({ preventScroll: true });
  }
  function closePlayer() {
    player.hidden = true;
    playing = null;
    const back = $('.d-tile, .d-poster, .d-prog.now', body);
    (back || $('.d-tab[aria-current="true"]')).focus({ preventScroll: true });
  }
  function showOsd() {
    player.classList.remove('hide-osd');
    clearTimeout(osdTimer);
    osdTimer = setTimeout(() => player.classList.add('hide-osd'), 4000);
  }
  function toast(t) {
    const el = $('#dToast');
    el.textContent = t;
    el.classList.add('show');
    clearTimeout(toast.t);
    toast.t = setTimeout(() => el.classList.remove('show'), 1600);
  }
  function zap(d) {
    if (!playing || playing.kind !== 'live') return;
    const cur = zapList.indexOf(channels[playing.i]);
    const next = zapList[(cur + d + zapList.length) % zapList.length];
    openChannel(channels.indexOf(next));
    toast(`${zapList.indexOf(next) + 1}  ${next[0]}`);
  }

  screen.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (!b) { if (!player.hidden) showOsd(); return; }
    if (b.dataset.tab) { tab = b.dataset.tab; cat = 'Alle'; render(); return; }
    if (b.dataset.cat) { cat = b.dataset.cat; render(); $(`.d-cat[data-cat="${CSS.escape(cat)}"]`, body)?.focus({ preventScroll: true }); return; }
    if (b.dataset.gch) { screen.dataset.guide = b.dataset.gch; render(); $(`[data-gch="${b.dataset.gch}"]`, body)?.focus({ preventScroll: true }); return; }
    if (b.dataset.ch) return openChannel(+b.dataset.ch);
    if (b.dataset.movie) return openTitle(movies[+b.dataset.movie]);
    if (b.dataset.series) return openTitle(series[+b.dataset.series]);
    const act = b.dataset.act;
    if (!act) return;
    showOsd();
    if (act === 'close') closePlayer();
    else if (act === 'prev') playing?.kind === 'live' ? zap(-1) : toast('−10 s');
    else if (act === 'next') playing?.kind === 'live' ? zap(1) : toast('+10 s');
    else if (act === 'play') {
      paused = !paused;
      $('#dPlayIcon').setAttribute('d', paused ? 'M8 5v14l11-7z' : 'M7 5h3v14H7zM14 5h3v14h-3z');
      $('#dVideo').style.animationPlayState = paused ? 'paused' : 'running';
    } else if (act === 'rec') toast('Aufnahme läuft · 60 min');
    else if (act === 'audio') toast('Tonspur: Deutsch · Stereo');
    else if (act === 'list') toast('Senderliste');
  });
  // Gerät wechseln: Oberfläche passt sich an wie in der App
  const devTabs = $$('.device-switch button'), indicator = $('.device-indicator');
  function placeIndicator() {
    const b = devTabs.find((x) => x.getAttribute('aria-selected') === 'true');
    indicator.style.width = `${b.offsetWidth}px`;
    indicator.style.transform = `translateX(${b.offsetLeft}px)`;
  }
  devTabs.forEach((b) => b.addEventListener('click', () => {
    devTabs.forEach((x) => x.setAttribute('aria-selected', String(x === b)));
    device.dataset.device = b.dataset.device;
    placeIndicator();
  }));
  addEventListener('resize', placeIndicator);
  requestAnimationFrame(placeIndicator);
  if (matchMedia('(max-width: 720px)').matches) $('.device-switch [data-device="phone"]').click();
  render();

  /* ================= Fernbedienungs-Navigation für die ganze Seite ================= */
  const FOCUSABLE = 'a[href], button:not([disabled]), summary, input, [tabindex]:not([tabindex="-1"])';
  function visible(el) {
    if (el.closest('[hidden]') || el.closest('.stage:not(.is-active)')) return false;
    const d = el.closest('details');
    if (d && !d.open && !el.matches('summary') && el.closest('summary') == null) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
  }
  function move(dir, from, scope, exclude) {
    const r = from.getBoundingClientRect();
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    let best = null, bestScore = Infinity;
    for (const el of $$(FOCUSABLE, scope)) {
      if (el === from || (exclude && exclude.contains(el)) || !visible(el)) continue;
      const c = el.getBoundingClientRect();
      const ex = c.left + c.width / 2, ey = c.top + c.height / 2;
      const dx = ex - cx, dy = ey - cy;
      let main, cross, overlap;
      if (dir === 'ArrowRight') { if (c.left < r.right - 4 && dx <= 4) continue; main = Math.max(0, c.left - r.right); cross = Math.abs(dy); overlap = c.top < r.bottom && c.bottom > r.top; }
      else if (dir === 'ArrowLeft') { if (c.right > r.left + 4 && dx >= -4) continue; main = Math.max(0, r.left - c.right); cross = Math.abs(dy); overlap = c.top < r.bottom && c.bottom > r.top; }
      else if (dir === 'ArrowDown') { if (c.top < r.bottom - 4 && dy <= 4) continue; main = Math.max(0, c.top - r.bottom); cross = Math.abs(dx); overlap = c.left < r.right && c.right > r.left; }
      else { if (c.bottom > r.top + 4 && dy >= -4) continue; main = Math.max(0, r.top - c.bottom); cross = Math.abs(dx); overlap = c.left < r.right && c.right > r.left; }
      const score = main + (overlap ? 0 : cross * 2.2);
      if (score < bestScore) { bestScore = score; best = el; }
    }
    return best;
  }
  document.addEventListener('keydown', (e) => {
    const a = document.activeElement;
    const inScreen = a && screen.contains(a);
    // Im Vorschau-Player: Hoch/Runter wechselt den Sender, Escape schließt
    if (inScreen && !player.hidden) {
      if (e.key === 'Escape' || e.key === 'Backspace' || e.key === 'BrowserBack' || e.key === 'GoBack') { e.preventDefault(); closePlayer(); return; }
      if (e.key === 'ArrowUp' || e.key === 'ArrowDown') { e.preventDefault(); showOsd(); zap(e.key === 'ArrowDown' ? 1 : -1); return; }
      showOsd();
    } else if (inScreen && (e.key === 'Escape' || e.key === 'Backspace' || e.key === 'GoBack')) {
      e.preventDefault();
      $('.d-tab[aria-current="true"]').focus({ preventScroll: true });
      return;
    }
    if (!e.key.startsWith('Arrow') || e.altKey || e.metaKey || e.ctrlKey) return;
    if (a && (a.matches('input:not([type="color"]), textarea, select, [contenteditable]'))) return;
    // Fernbedienungstasten auf der Fernbedienung in der Seite anzeigen
    const keyMap = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right' };
    if (a && a.classList.contains('rk')) { /* normale Navigation */ }
    let target = null;
    const dlg = $('dialog[open]');
    if (dlg) target = move(e.key, a, dlg, null);
    else if (!a || a === document.body) target = $('#heroDownload');
    else if (inScreen) {
      target = move(e.key, a, player.hidden ? screen : player, player.hidden ? player : null);
      if (!target && player.hidden) target = move(e.key, screen, document, screen); // aus der Vorschau heraus
    } else {
      target = move(e.key, a, document, null);
      if (target && screen.contains(target) && player.hidden) target = $('.d-tab[aria-current="true"]');
    }
    if (!target) return;
    e.preventDefault();
    target.focus({ preventScroll: true });
    if (keyMap[e.key] && isTv) showKeyQuiet(keyMap[e.key]);
    const scroller = screen.contains(target) ? 'nearest' : 'center';
    target.scrollIntoView({ block: scroller, inline: 'nearest', behavior: reduced ? 'auto' : 'smooth' });
    if (screen.contains(target) && !inScreen) screen.scrollIntoView({ block: 'center', behavior: reduced ? 'auto' : 'smooth' });
  });
  function showKeyQuiet(k) { $$('.rk').forEach((b) => b.classList.toggle('on', b.dataset.key === k)); }
  // Auf dem Fernseher gleich einen Startpunkt fokussieren
  if (isTv) setTimeout(() => $('#heroDownload').focus({ preventScroll: true }), 1700);
})();
