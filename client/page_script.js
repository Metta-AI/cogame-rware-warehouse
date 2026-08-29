(function () {
  'use strict';

  // Shared replay chrome (chrome_common.js, spliced over the CHROME_COMMON
  // marker by the server / dist bundle; the literal marker must not appear
  // inside this script or the splice would corrupt it). A raw file:// open of
  // this source has no splice -- same non-functional baseline as the missing
  // BROADCAST_CORE -- so fail loud and early instead of throwing mid-file.
  if (!window.ChromeCommon) {
    console.error('replay_broadcast: chrome_common.js missing - this page must be served spliced (native server or dist bundle), not opened raw.');
    return;
  }
  // The inherited chrome reads its engine constants from window.CTF_WIRE, and
  // chrome_common.js is coworld-ctf's file BYTE FOR BYTE (pinned by
  // tests/test_rware_viewer.nim), so the two names are joined here, in this
  // game's own fork of the page IIFE, before the chrome is instantiated.
  // Without it the chrome falls back to ctf's [1,2,3,4,8,16] chip row: a 3x
  // and a 16x this engine has no command for, and no half-speed chip at all.
  window.CTF_WIRE = window.RWARE_WIRE;
  var C = window.ChromeCommon({
    send: function (cmd) { send(cmd); },
    sendPov: function () {},
    getState: function () { return lastState; }
  });
  // Aliases so the per-view code below reads exactly as before.
  var RED = C.RED, BLUE = C.BLUE, AMBER = C.AMBER, PAPER = C.PAPER;
  var GREEN = C.GREEN, YELLOW = C.YELLOW;
  var TEAM_ORDER = C.TEAM_ORDER, TEAM_COLOR = C.TEAM_COLOR;
  var teamCol = C.teamCol, activeTeams = C.activeTeams, teamOf = C.teamOf;
  var otherTeam = C.otherTeam, stripSeatSuffix = C.stripSeatSuffix;
  var teamPolicies = C.teamPolicies, teamName = C.teamName, teamHeadline = C.teamHeadline;
  var rosterName = C.rosterName, setName = C.setName, esc = C.esc, fmt = C.fmt;
  var togglePov = C.togglePov, renderClock = C.renderClock, renderTransport = C.renderTransport;
  var ingestLullSpans = C.ingestLullSpans, renderLullSpans = C.renderLullSpans;
  var markBeat = C.markBeat, killMarkerTeam = C.killMarkerTeam, renderBeatMarkers = C.renderBeatMarkers;
  var captureTeam = C.captureTeam, ingestBeats = C.ingestBeats, setVerdict = C.setVerdict;
  var ingestLeadSeries = C.ingestLeadSeries, recordMomentum = C.recordMomentum;
  var renderMomentum = C.renderMomentum;
  var getSpoilers = C.getSpoilers, setSpoilers = C.setSpoilers;

  // Engine-authoritative wire constants (read via the shared chrome; the
  // fallback literals for raw file:// opens live in chrome_common.js).
  var WIRE = C.WIRE, SPEEDS = C.SPEEDS, FPS = C.FPS;

  // ART_BASE, not a root-absolute "/client/...": this page is served from
  // three places and a leading slash is only correct at one of them.
  //  - native server, bare:      /client/replay          -> "" + /client/...
  //  - native server, proxied:   /<prefix>/client/replay
  //  - the STATIC WASM BUNDLE:   .../index.html, where the assets sit NEXT TO
  //    the page and there is no server at all.
  var ART_BASE = window.RwareStaticReplay
    ? '.'
    : location.pathname.replace(/\/clients?\/[^/]*$/, '') + '/client';

  // Two independent tempo levers, both the starter's:
  //  (1) ANIM_MAX_FACTOR -- chrome beat animations never play faster than this
  //      no matter the replay speed, so feed rows keep their read time.
  //  (2) DWELL_FLOOR_MS -- a beat's on-screen hold has a wall-clock minimum.
  var ANIM_MAX_FACTOR = 2;
  var DWELL_FLOOR_MS = { feed: 2600, banner: 1900, curtain: 2400, read: 600 };
  function animFactor() {
    var sp = (lastState && lastState.sp) || 1;
    return Math.min(sp, ANIM_MAX_FACTOR);
  }
  function dwellFloor(kind) {
    return DWELL_FLOOR_MS[kind] || DWELL_FLOOR_MS.read;
  }
  var beatPulseTimer = null;
  function beatPulse() {
    stage.classList.add('beat-active');
    if (beatPulseTimer) clearTimeout(beatPulseTimer);
    beatPulseTimer = setTimeout(function () {
      stage.classList.remove('beat-active');
      beatPulseTimer = null;
    }, dwellFloor('read'));
  }

  var $ = C.$;
  var viewport = $('viewport');
  var stage = $('stage');
  var canvas = $('board');
  var statusEl = $('status');

  // ---- pre-load curtain: the muster room -----------------------------------
  // The stage opens on this scene while the wasm sim boots. The art frames are
  // wired here (their base path is delivery-mode dependent); the first
  // ingested frame calls dismissLockerRoom(), which fades the room out after a
  // short minimum dwell -- a sub-second load would otherwise flash the scene
  // like a glitch.
  var lockerEl = $('lockerroom');
  var LOCKER_MIN_DWELL_MS = 900;
  var lockerShownAt = Date.now();
  var lockerCapTimer = null, lockerGone = false;
  (function buildLockerRoom() {
    var artBase = ART_BASE + '/art/lockerroom';
    $('lk-bg').src = artBase + '/bg.jpg';
    // Sprite geometry baked by the extraction script: ax/ay anchor each cog's
    // bottom-center on the plate, w/h size each pose -- all in % of the plate,
    // so everything scales together. FOUR robots here, one per seat, in the
    // four colours the starter ships soldier art in.
    var LK_BOTS = {
      red:    { ax: 18.0, ay: 77.0, cyc: 4.1,
        poses: [{ f: 1, w: 15.15, h: 15.79 }, { f: 2, w: 13.93, h: 17.19 },
                { f: 3, w: 13.52, h: 16.87 }, { f: 5, w: 13.83, h: 17.63 },
                { f: 6, w: 14.73, h: 18.06 }] },
      blue:   { ax: 39.0, ay: 76.67, cyc: 3.8,
        poses: [{ f: 1, w: 14.63, h: 15.25 }, { f: 2, w: 12.92, h: 18.6 },
                { f: 3, w: 13.83, h: 18.81 }, { f: 5, w: 14.63, h: 17.63 },
                { f: 6, w: 12.62, h: 19.68 }] },
      green:  { ax: 61.0, ay: 77.0, cyc: 4.4,
        poses: [{ f: 1, w: 14.15, h: 15.79 }, { f: 2, w: 12.93, h: 17.19 },
                { f: 3, w: 13.52, h: 17.87 }, { f: 5, w: 13.83, h: 17.63 },
                { f: 6, w: 13.73, h: 18.06 }] },
      yellow: { ax: 82.0, ay: 76.67, cyc: 3.5,
        poses: [{ f: 1, w: 14.63, h: 15.25 }, { f: 2, w: 12.92, h: 18.6 },
                { f: 3, w: 13.83, h: 18.81 }, { f: 5, w: 13.63, h: 17.63 },
                { f: 6, w: 12.62, h: 19.68 }] }
    };
    var spritesEl = $('lk-sprites');
    ['red', 'blue', 'green', 'yellow'].forEach(function (bot) {
      var b = LK_BOTS[bot];
      var maxW = 0, maxH = 0;
      b.poses.forEach(function (p) {
        maxW = Math.max(maxW, p.w);
        maxH = Math.max(maxH, p.h);
      });
      var wrap = document.createElement('div');
      wrap.className = 'lk-boto';
      wrap.style.left = (b.ax - maxW / 2) + '%';
      wrap.style.top = (b.ay - maxH) + '%';
      wrap.style.width = maxW + '%';
      wrap.style.height = maxH + '%';
      b.poses.forEach(function (p, ix) {
        var img = document.createElement('img');
        img.alt = '';
        img.src = artBase + '/' + bot + '_' + p.f + '.webp';
        img.style.width = (p.w / maxW * 100) + '%';
        img.style.setProperty('--cyc', b.cyc + 's');
        img.style.animationDelay = (ix * b.cyc / b.poses.length) + 's';
        wrap.appendChild(img);
      });
      spritesEl.appendChild(wrap);
    });

    var bgImg = $('lk-bg');
    function fitLockerSprites() {
      spritesEl.style.left = bgImg.offsetLeft + 'px';
      spritesEl.style.top = bgImg.offsetTop + 'px';
      spritesEl.style.width = bgImg.offsetWidth + 'px';
      spritesEl.style.height = bgImg.offsetHeight + 'px';
    }
    bgImg.addEventListener('load', fitLockerSprites);
    if (window.ResizeObserver) new ResizeObserver(fitLockerSprites).observe(bgImg);
    window.addEventListener('resize', fitLockerSprites);
    fitLockerSprites();

    // rotating prep-talk line under the scene
    var lines = [
      'Charging the robots\u2026',
      'Reading the request board\u2026',
      'Chalking the aisles\u2026',
      'One order every twenty ticks\u2026',
      'Clearing the queue lane\u2026',
      'Counting the empty slots\u2026'
    ];
    var capEl = $('lk-cap'), capIx = 0;
    lockerCapTimer = setInterval(function () {
      capEl.classList.add('swap');
      setTimeout(function () {
        capIx = (capIx + 1) % lines.length;
        capEl.textContent = lines[capIx];
        capEl.classList.remove('swap');
      }, 180);
    }, 2600);
  })();
  function dismissLockerRoom() {
    if (lockerGone) return;
    lockerGone = true;
    var wait = Math.max(0, LOCKER_MIN_DWELL_MS - (Date.now() - lockerShownAt));
    setTimeout(function () {
      lockerEl.classList.add('gone');
      setTimeout(function () {
        lockerEl.style.display = 'none';
        if (lockerCapTimer) { clearInterval(lockerCapTimer); lockerCapTimer = null; }
      }, 650);
    }, wait);
  }

  // ---- embed mode ----------------------------------------------------------
  // When loaded inside a shell (?embed=1) this client renders ONLY the board
  // (its own scorebug/transport/feed chrome is hidden by CSS via
  // body[data-embed]) and streams each parsed state frame up to the parent
  // shell over postMessage.
  var EMBED = false;
  try { EMBED = new URLSearchParams(location.search).get('embed') === '1'; } catch (e) {}
  if (EMBED) document.body.setAttribute('data-embed', '1');

  // Tick deep-link (?t=<tick>): seek there on load via the same s: command the
  // scrubber uses. One-shot, fired on the first ingested frame so the replay
  // runtime is ready.
  var SEEK_T = null;
  try {
    var seekRaw = new URLSearchParams(location.search).get('t');
    if (seekRaw != null && /^\d+$/.test(seekRaw)) SEEK_T = parseInt(seekRaw, 10);
  } catch (e) {}

  function postToShell(type, payload) {
    if (!EMBED || window.parent === window) return;
    try { window.parent.postMessage({ src: 'rware-replay', type: type, data: payload }, '*'); } catch (e) {}
  }

  // The whole replay is ONE fixed-aspect composition locked to the board's
  // native size. The board is a fixed 10x11 (or 16x11) integer grid with no
  // off-frame area, which is the reason the zoom bar and the minimap are gone:
  // relayout() fits the whole warehouse at every width, and in a 360x203
  // featured-match embed the binding dimension is the HEIGHT, so both shipped
  // floors render at 18 px per cell. The aspect is re-read from the first
  // frame's board descriptor, so the wide floor letterboxes correctly too.
  var BOARD_ASPECT = 10 / 11;

  // ---- core (board renderer + WS) ----
  var lastState = null;
  var RW_CTX = null;             // filled at the end of this IIFE (hoisted)
  // A scrubber click that arrives before the first chrome frame is REMEMBERED
  // and resolved on the first frame that carries the axis -- the same one-shot
  // shape as ?t=.
  var SEEK_FRAC = null;
  var replayAdapter = window.RwareStaticReplay || null;
  var coreConfig = {
    canvas: canvas,
    websocket: replayAdapter ? false : websocketUrl(),
    onText: function (txt) { onFrame(txt); },
    onStatus: function (st) { onStatus(st); },
    onFirstFrame: function () { core.setViewportFit(); }
  };
  var core = replayAdapter
    ? replayAdapter.createCore(coreConfig)
    : window.BroadcastCore.create(coreConfig);

  function websocketUrl() {
    var scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    var prefix = location.pathname.replace(/\/clients?\/[^/]*$/, '');
    return scheme + '//' + location.host + prefix + '/global';
  }

  postToShell('boot');

  function send(cmd) { core.sendCommand(cmd); }

  if (EMBED) {
    window.addEventListener('message', function (ev) {
      var m = ev.data;
      if (!m || m.src !== 'rware-shell') return;
      if (m.type === 'cmd' && typeof m.cmd === 'string') send(m.cmd);
      else if (m.type === 'seek' && m.tick != null) send('s:' + m.tick);
    });
  }

  function onStatus(st) {
    statusEl.textContent = st;
    statusEl.classList.toggle('show', st !== 'open');
  }

  // ============================================================
  //  Frame ingest
  // ============================================================
  var lastTick = -1;
  var lastFf = false;   // previous frame's fast-forward state (jump detection)
  // (beat markers, lull spans, beats timeline and momentum state live in the
  // shared chrome closure -- see chrome_common.js)

  function onFrame(txt) {
    var s;
    try { s = JSON.parse(txt); } catch (e) { return; }
    if (!s || !s.rw) return;
    lastState = s;
    if (s.rw && s.rw.board && s.rw.board.w && s.rw.board.h) {
      var aspect = s.rw.board.w / s.rw.board.h;
      if (Math.abs(aspect - BOARD_ASPECT) > 0.001) {
        BOARD_ASPECT = aspect;
        relayout();
      }
    }
    dismissLockerRoom();

    // A backward jump (a seek, or a loop restart) clears everything that
    // accumulates forward, so the chrome never shows a stale future.
    var jumped = (s.t < lastTick) || (lastFf && !s.ff);
    if (jumped) { clearFeed(); clearBanners(); }
    lastTick = s.t;
    lastFf = !!s.ff;

    ingestLullSpans(s);
    ingestBeats(s);
    ingestLeadSeries(s);
    recordMomentum(s);
    renderTransport(s);
    renderScorebug(s);
    renderClockLine(s);
    renderMismatch(s);
    renderEndcard(s);
    if (window.RwareChrome) window.RwareChrome.frame(s, RW_CTX, jumped);

    if (SEEK_T != null && s.en) { var t = SEEK_T; SEEK_T = null; send('s:' + t); }
    if (SEEK_FRAC != null && s.en) {
      var frac = SEEK_FRAC; SEEK_FRAC = null; seekToFraction(s, frac);
    }
    postToShell('frame', s);
  }

  // ---------- scorebug ----------
  // FOUR plates, two in #plates-l and two in #plates-r: the seat's REAL policy
  // name (spectator side only), its in-game alias, its colour chip, its own
  // delivered count as the numeral, and a fallback glyph on any seat that has
  // taken one.
  var SEAT_COLOUR = { red: RED, blue: BLUE, green: GREEN, yellow: YELLOW };
  var sbBuilt = false;
  function ensureScorebug() {
    if (sbBuilt) return;
    sbBuilt = true;
    [['plates-l', [0, 1]], ['plates-r', [2, 3]]].forEach(function (pair) {
      var host = $(pair[0]);
      var html = '';
      pair[1].forEach(function (i) {
        html +=
          '<div class="plate' + (pair[0] === 'plates-r' ? ' side-r' : '') +
          '" id="plate-' + i + '">' +
          '<span class="colour-chip" id="chip-' + i + '"></span>' +
          '<span class="plate-name" id="pname-' + i + '"></span>' +
          '<span class="plate-alias" id="palias-' + i + '"></span>' +
          '<span class="deliv-label">Delivered</span>' +
          '<span class="deliv-num" id="pdeliv-' + i + '"></span>' +
          '<span class="fb-glyph" id="pfb-' + i + '"></span>' +
          '</div>';
      });
      host.innerHTML = html;
    });
    // The plates are built on the FIRST frame, after relayout() has already
    // measured an empty scorebug -- so --topband is a stale, too-small number
    // until something re-measures it, and every overlay anchored under the
    // band (the request rail, the jam chip) lands on top of the plates.
    // Re-run the fixed-point pass now that the band has its real content.
    setTimeout(relayout, 0);
  }
  function renderScorebug(s) {
    ensureScorebug();
    var seats = s.rw.seats || [];
    for (var i = 0; i < 4; i++) {
      var seat = seats[i] || {};
      var col = SEAT_COLOUR[seat.colour] || PAPER;
      var plate = $('plate-' + i);
      if (plate) plate.style.color = col;
      var chip = $('chip-' + i);
      if (chip) chip.style.background = col;
      setName('pname-' + i, teamHeadline(seat.name || ''));
      setName('palias-' + i, seat.alias || '');
      setName('pdeliv-' + i, String(seat.delivered != null ? seat.delivered : 0));
      setName('pfb-' + i, (seat.fallbacks > 0) ? '\u21af' : '');
    }
  }

  // ---------- clock ----------
  // #clock-time is the big DELIVERED numeral with the par beneath it;
  // #clock-caption reads the tick, the turn, the jam count and the blocked
  // total. renderClock (chrome_common) is deliberately not called: its
  // captions are for a duel with a countdown, and this is one cooperative
  // shift scored on shelves delivered.
  function renderClockLine(s) {
    var rw = s.rw;
    setName('clock-time', 'DELIVERED ' + rw.delivered);
    setName('clock-caption',
      '/ ' + rw.par + ' par \u00b7 tick ' + rw.tick + '/' + rw.maxTicks +
      ' \u00b7 turn ' + Math.max(1, rw.turn) + '/' + rw.turns +
      ' \u00b7 jam ' + rw.jams + ' \u00b7 blocked ' + rw.blocked);
  }

  function renderMismatch(s) {
    var el = $('mmwarn');
    var tick = s.rw.mismatchTick;
    if (tick != null && tick >= 0) {
      el.textContent = 'Replay hash mismatch at tick ' + tick +
        ' \u2014 showing recorded orders';
      el.classList.add('show');
    } else {
      el.classList.remove('show');
    }
  }

  // ---------- match feed ----------
  var feedEl = $('killfeed');
  var MAX_FEED = 4;
  function pushFeed(row) {
    feedEl.insertBefore(row, feedEl.firstChild);
    while (feedEl.children.length > MAX_FEED) feedEl.removeChild(feedEl.lastChild);
    // Dwell floor (lever 2): a wall-clock minimum so the row reads even at 8x.
    var hold = dwellFloor('feed');
    // animFactor cap (lever 1): the slide-in duration never dips below its
    // read-time, so the row still overshoots-and-settles legibly at high speed.
    row.style.animationDuration = (250 / animFactor()) + 'ms';
    setTimeout(function () {
      if (row.parentNode) { row.classList.add('leaving'); setTimeout(function () { if (row.parentNode) row.parentNode.removeChild(row); }, 300); }
    }, hold);
  }
  function clearFeed() { feedEl.innerHTML = ''; }

  // ---------- banner lane queue (one at a time, min hold) ----------
  var bannerEl = $('bannerlane');
  var bannerQueue = [];
  var bannerBusy = false;
  function banner(text, cls) {
    bannerQueue.push({ text: text, cls: cls });
    pumpBanner();
  }
  function pumpBanner() {
    if (bannerBusy || !bannerQueue.length) return;
    bannerBusy = true;
    var b = bannerQueue.shift();
    var chip = document.createElement('div');
    chip.className = 'banner-chip ' + b.cls;
    chip.textContent = b.text;
    bannerEl.appendChild(chip);
    chip.style.animationDuration = (300 / animFactor()) + 'ms';
    var hold = dwellFloor('banner');
    setTimeout(function () {
      chip.classList.add('leaving');
      setTimeout(function () {
        if (chip.parentNode) chip.parentNode.removeChild(chip);
        bannerBusy = false;
        pumpBanner();
      }, 260);
    }, hold);
  }
  function clearBanners() {
    bannerQueue = [];
    bannerEl.innerHTML = '';
    bannerBusy = false;
  }

  // ============================================================
  //  End-card -- the END SEGMENT: verdict, win condition and match stats.
  //  It stops at var(--band) so the scrubber stays clickable underneath, and
  //  every seek dismisses it (both the starter's rules, kept).
  // ============================================================
  var ecBuilt = false;
  function ensureEndcardTeams() {
    if (ecBuilt) return;
    ecBuilt = true;
    $('ec-teams').innerHTML = '<div class="ec-team" id="ec-fleet"></div>';
  }
  function renderEndcardRows(s) {
    var card = s.rw.endcard;
    var html = '<div class="ec-thead"><span>Robot</span><span>Delivered</span>' +
      '<span>Stowed</span><span>Blocked</span><span>Jams</span></div>';
    for (var i = 0; i < card.rows.length; i++) {
      var row = card.rows[i];
      var col = SEAT_COLOUR[row.colour] || PAPER;
      html += '<div class="ec-trow"><span style="color:' + col + '">' +
        esc(row.alias) + ' \u00b7 ' + esc(teamHeadline(row.name || '')) +
        '</span><span>' + row.delivered + '</span><span>' + row.stowed +
        '</span><span>' + row.blocked + '</span><span>' + row.jams +
        '</span></div>';
    }
    html += '<div class="ec-tfoot"><span class="fl-cap">Shelves delivered</span>' +
      '<span class="fl-num">' + card.teamDelivered + '</span></div>';
    return html;
  }
  function renderEndcard(s) {
    var card = s.rw.endcard;
    var el = $('endcard');
    if (!card || s.ph !== 'gameover' || !card.complete) {
      el.classList.remove('on');
      return;
    }
    ensureEndcardTeams();
    setName('ec-headline', card.teamDelivered + ' SHELVES DELIVERED \u2014 PAR ' +
      card.par + (card.met ? ' MET' : ' MISSED'));
    setName('ec-wincond', 'TEAM SCORE ' + card.score);
    setName('ec-how', card.jams + ' jams, ' + card.jamTicks +
      ' ticks lost, longest ' + card.longestJamTicks + ' \u00b7 ' + card.reason);
    $('ec-fleet').innerHTML =
      '<div class="ec-tname">THE FLEET</div>' + renderEndcardRows(s);
    setName('ec-replay', '');
    el.classList.add('on');
    // The shared chrome's verdict cap (#scrub-win) and WINS chip (#win-chip)
    // are fed by ingestBeats' `gameover` kind, which this game never emits --
    // so both ids stayed empty for the whole replay. Feed them here instead,
    // through the chrome's own documented fallback path, in this game's
    // vocabulary: a cooperative shift has no winner, it has a par.
    setVerdict(card.met
      ? { winner: 'THE FLEET', t: s.t }
      : { draw: true, t: s.t });
  }

  // ============================================================
  //  Transport wiring -- DOM controls emit the chat chars plus the
  //  whole-string s: seek command.
  // ============================================================
  function togglePlay() { send(' '); }
  // (speed chips + their speed->command map live in the shared chrome)
  $('btn-play').addEventListener('click', togglePlay);
  // ...except the HALF-SPEED chip. The chrome builds a chip for every entry of
  // WIRE.speeds, but its speed->command map is ctf's whole-number one, so the
  // 0.5x chip it builds for this engine has no command of its own. Give it
  // one here: '5' is replay_runtime's half-speed char, and it is the same char
  // the keyboard's digit branch already forwards.
  $('speedchips').querySelector('button[aria-label="0.5x speed"]')
    .addEventListener('click', function () { send('5'); });
  $('btn-restart').addEventListener('click', function () { send(','); });
  $('btn-back').addEventListener('click', function () { send('b'); });
  $('btn-fwd').addEventListener('click', function () { send('.'); });
  $('btn-end').addEventListener('click', function () { send('e'); });
  $('btn-loop').addEventListener('click', function () { send('r'); });
  $('btn-skip').addEventListener('click', function () { send('f'); });

  // click-to-seek: map x-fraction to a tick and send s:<tick>
  function seekToFraction(s, frac) {
    var st = Math.max(0, s.st || 0);
    var mx = Math.max(st + 1, s.mx || 1);
    send('s:' + (st + Math.round(frac * (mx - st))));
    var card = $('endcard');
    if (card) card.classList.remove('on');
  }

  $('scrub').addEventListener('click', function (ev) {
    var rect = this.getBoundingClientRect();
    var frac = Math.min(1, Math.max(0, (ev.clientX - rect.left) / rect.width));
    // The axis lives on the frame, so a click before the first frame cannot be
    // mapped yet -- QUEUE it rather than dropping it. A dropped first click is
    // invisible: the board is already drawn and the viewer just does not move.
    if (!lastState || !lastState.en) { SEEK_FRAC = frac; return; }
    seekToFraction(lastState, frac);
  });

  // keyboard shortcuts mirror the transport
  window.addEventListener('keydown', function (ev) {
    if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
    var k = ev.key;
    if (k === ' ') { ev.preventDefault(); togglePlay(); }
    else if (k === ',' || k === '<') send(',');
    else if (k === '.' || k === '>') send('.');
    else if (k === 'b') send('b');
    else if (k === 'e') send('e');
    else if (k === 'r') send('r');
    else if (k === 'f') send('f');
    else if (k === 'o') {
      setSpoilers(!getSpoilers());
      // the appended block gates its own markers -- and a toggle while paused
      // has no frame coming to do it
      if (window.RwareChrome && window.RwareChrome.applySpoilers) {
        window.RwareChrome.applySpoilers(lastState);
      }
    }
    else if (k >= '1' && k <= '9') send(k);
    else if (k === 'Escape') postToShell('esc');
  });

  // ============================================================
  //  Fixed-aspect fit: size the composition to the board's native aspect
  //  inside the embed box, then scale the whole thing (board + overlays) as
  //  one unit. Chrome sizes off the STAGE width, so overlays stay locked to
  //  the graphics at any container shape.
  // ============================================================
  function relayout() {
    var boxW = viewport.clientWidth, boxH = viewport.clientHeight;
    if (!boxW || !boxH) return;
    // The board region fits the board aspect into the box BETWEEN a reserved
    // top band (the scorebug) and bottom band (the transport), so neither ever
    // sits over play. Each band's pixel height depends on --hudscale (-> board
    // width) and the board fit depends on the bands, so iterate to a FIXED
    // POINT: stop as soon as a pass measures the same bands it was laid out
    // with.
    var scorebug = document.getElementById('scorebug');
    var transport = document.getElementById('transport');
    var root = document.documentElement;
    var topBand = parseFloat(getComputedStyle(root).getPropertyValue('--topband')) || 0;
    var band = parseFloat(getComputedStyle(root).getPropertyValue('--band')) || 0;
    var stageW = 0, stageH = 0;
    for (var pass = 0; pass < 4; pass++) {
      var prevTop = topBand, prevBand = band;
      var availH = Math.max(1, boxH - topBand - band);
      var boardW, boardH;
      if (boxW / availH > BOARD_ASPECT) {
        boardH = availH; boardW = Math.round(availH * BOARD_ASPECT);
      } else {
        boardW = boxW; boardH = Math.round(boxW / BOARD_ASPECT);
      }
      stageW = boardW; stageH = boardH + topBand + band;
      stage.style.width = stageW + 'px';
      stage.style.height = stageH + 'px';
      // One scale for the whole composition: chrome was authored against a
      // ~760px-wide reference board, so --hudscale is the board's on-screen
      // width over that reference (clamped so a huge featured embed doesn't
      // bloat the chrome and a tiny 360px floor stays legible).
      var scale = Math.max(0.5, Math.min(1.6, boardW / 760));
      root.style.setProperty('--hudscale', scale.toFixed(3));
      // UNDER 640px of board the density drops to .tiny and the plate labels
      // go. The starter toggles at 620; this fork uses the 640 the checklist
      // and the game block's own CSS comment both state, so the 621-640 px
      // band is no longer a strip where the labels stay and the comment lies.
      stage.classList.toggle('tiny', boardW < 640);
      // Measure each band's natural height -> reserve exactly that.
      topBand = scorebug ? scorebug.offsetHeight : 0;
      band = transport ? transport.offsetHeight : 0;
      root.style.setProperty('--topband', topBand + 'px');
      root.style.setProperty('--band', band + 'px');
      if (Math.abs(topBand - prevTop) < 0.5 && Math.abs(band - prevBand) < 0.5) break;
    }
    core.setViewportFit();
  }
  var ro = new ResizeObserver(relayout);
  ro.observe(viewport);
  window.addEventListener('resize', relayout);

  // The context the appended rware-warehouse block reads the inherited chrome
  // through. Declared here (hoisted `var`, so onFrame sees it however early
  // the first frame lands) rather than duplicating any of it: the game block
  // must not re-implement naming, escaping, feed insertion or the transport.
  RW_CTX = {
    $: $, C: C, esc: esc, fmt: fmt, send: send,
    teamCol: teamCol, teamHeadline: teamHeadline,
    pushFeed: pushFeed, banner: banner, beatPulse: beatPulse,
    core: core,
    getState: function () { return lastState; }
  };
  if (window.RwareChrome) window.RwareChrome.install(RW_CTX);
  // Exposed for tools/ci/renderer_fixture.html ONLY: the worst-case text
  // fixture drives the SHIPPED page's own feed path rather than
  // re-implementing it (the particle-worlds 2026-08-26 scar), and it needs the
  // same context object the game block is installed with.
  window.RWARE_CTX = RW_CTX;

  relayout();
  core.start();
})();
