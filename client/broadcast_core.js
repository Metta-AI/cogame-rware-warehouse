// broadcast_core.js — rware-warehouse board renderer and state channel.
//
// Forked from coworld-ctf/client/broadcast_core.js, but a RETARGETED REWRITE,
// not a line-for-line fork: the starter's 1,407 lines are built around the
// Bitworld sprite protocol, vendored SnappyJS and an interpolating pixel
// camera, and none of that survives an integer cell grid. What IS kept is the
// CONTRACT the surrounding chrome and the static adapter call through, method
// for method:
//
//   * the module shape -- a dependency-free IIFE publishing
//     `window.BroadcastCore.create`;
//   * every method `replay-viewer/static_replay_worker.js` and
//     `client/page_script.js` invoke: start/stop/ingest/sendCommand/clickMap,
//     zoomAt/setZoom/panBy/panByMap/panTo/resetView/attachMinimap (deliberate
//     no-ops for a fixed board), getTransform/setViewportSize/setViewportFit,
//     getState, getPaceStats;
//   * the callback contract (onText/onStatus/onFirstFrame/onTransform/
//     onSendPacket), the canvas/DPR sizing, the whole-board camera;
//   * the `getPaceStats()` shape `static_replay.js` mirrors
//     ({enabled, queued, presented, interval, draws});
//   * `pushFeed(text)`'s SIGNATURE, because the static adapter latches on a
//     throw from it (cogball 0.1.4) -- the ONE name in this file whose shape,
//     not whose body, is the inherited thing;
//   * the websocket mode the native server page uses, and the `?embed=1` path.
//
// The starter's wire-constants global read is renamed to
// `window.RWARE_WIRE`, emitted by tools/gen_wire_constants.nim.
//
// DELETED: the Bitworld sprite-protocol compositor and every ctf-specific
// draw call (flags, paint, hills, hearts, grenades) and the whole FPV
// pipeline. This game has none of them, and its board is a 10x11 / 16x11
// INTEGER GRID rather than a pixel arena, so the wire is one UTF-8 JSON state
// object per frame instead of a binary sprite stream.
//
// ADDED: drawWarehouse, drawShelves, drawRobots, drawJam, drawRequestRail.
//
// ART. Real art, from the starter's shipped assets -- no placeholders and no
// solid-colour squares. The floor is arena_floor.png tiled and darkened 18 %
// with chalk aisle lines, the two workstation pads and the shelf-block shadow,
// baked ONCE per board size. Shelf crates are baked from the starter's crate
// texture (client/art/walls/wall_h.jpg) tinted through data/pallete.png at
// three sizes with a 1 px rim. Robots are baked at load from
// data/soldier_{red,blue,green,yellow}.png into three chip sizes x four
// facings x loaded/empty -- 96 pre-baked chips -- so drawing four robots a
// frame is four blits.
//
// The native replay page runs this core in a Window. The static bundle runs
// the SAME file in a Dedicated Worker with an OffscreenCanvas. One
// implementation, so a rendering fix cannot drift between the two delivery
// modes.

(function () {
  'use strict';

  var globalScope = typeof window !== 'undefined' ? window : self;
  var requestFrame = typeof globalScope.requestAnimationFrame === 'function'
    ? globalScope.requestAnimationFrame.bind(globalScope)
    : function (cb) { return setTimeout(function () { cb(Date.now()); }, 1000 / 60); };

  var WIRE = globalScope.RWARE_WIRE || {};
  var SPEEDS = WIRE.speeds || [1, 2, 4, 8];
  var FPS = WIRE.fps || 30;

  var SEAT_COLOURS = ['#e0523a', '#3f7cc4', '#57a05a', '#d9a441'];
  var SEAT_NAMES = ['red', 'blue', 'green', 'yellow'];
  var PAPER = '#f2e8d8';
  var AMBER = '#d9a441';
  var CHALK = 'rgba(242,232,216,0.55)';

  var FLASH_FRAMES = 10;    // a delivered pad flashes green this long

  function createCanvasSurface() {
    if (typeof document !== 'undefined') return document.createElement('canvas');
    if (typeof OffscreenCanvas !== 'undefined') return new OffscreenCanvas(1, 1);
    throw new Error('Canvas rendering is unavailable in this execution context');
  }

  // Asset base. This file is served from two places and a leading slash is
  // only correct at one of them:
  //   native server, page or proxied  ->  <prefix>/client/…
  //   the STATIC WASM BUNDLE          ->  the assets sit next to the worker
  var ART_BASE = (typeof document === 'undefined')
    ? './'
    : (location.pathname.replace(/\/clients?\/[^/]*$/, '') + '/client/');

  function loadBitmap(name) {
    return fetch(ART_BASE + name, { credentials: 'omit' })
      .then(function (r) {
        if (!r.ok) throw new Error(name + ': HTTP ' + r.status);
        return r.blob();
      })
      .then(function (b) { return createImageBitmap(b); });
  }

  var CHIP_SIZES = [12, 18, 28];
  var FACINGS = 4;          // 0 up, 1 down, 2 left, 3 right (upstream order)
  var CHEVRON = [
    [0, -1], [0, 1], [-1, 0], [1, 0]
  ];

  function bakeRobotChips(bitmap, colour) {
    // Three sizes x four facings x loaded/empty = 24 chips per colour, 96 for
    // the fleet. Each is the starter's soldier art composited once with its
    // colour rim, its facing chevron and, for the loaded variant, the raised
    // crate silhouette that says "this robot cannot pass under a shelf".
    var kit = [];
    for (var s = 0; s < CHIP_SIZES.length; s++) {
      kit[s] = [];
      for (var f = 0; f < FACINGS; f++) {
        kit[s][f] = [];
        for (var loaded = 0; loaded < 2; loaded++) {
          var size = CHIP_SIZES[s];
          var surface = createCanvasSurface();
          surface.width = size;
          surface.height = size;
          var c = surface.getContext('2d');
          c.clearRect(0, 0, size, size);
          if (bitmap) {
            c.drawImage(bitmap, 0, 0, bitmap.width, bitmap.height,
              1, 1, size - 2, size - 2);
          } else {
            c.fillStyle = colour;
            c.beginPath();
            c.arc(size / 2, size / 2, size / 2 - 1.5, 0, Math.PI * 2);
            c.fill();
          }
          // colour rim: two adjacent robots never read as one blob
          c.strokeStyle = colour;
          c.lineWidth = Math.max(1, Math.round(size / 12));
          c.beginPath();
          c.arc(size / 2, size / 2, size / 2 - 1, 0, Math.PI * 2);
          c.stroke();
          // facing chevron
          var dx = CHEVRON[f][0], dy = CHEVRON[f][1];
          var r = size / 2 - 1;
          c.fillStyle = PAPER;
          c.beginPath();
          c.moveTo(size / 2 + dx * r, size / 2 + dy * r);
          c.lineTo(size / 2 + dx * r * 0.45 - dy * r * 0.42,
            size / 2 + dy * r * 0.45 + dx * r * 0.42);
          c.lineTo(size / 2 + dx * r * 0.45 + dy * r * 0.42,
            size / 2 + dy * r * 0.45 - dx * r * 0.42);
          c.closePath();
          c.fill();
          if (loaded) {
            // the crate on the forks, with its drop shadow: "who is loaded"
            // reads at a glance, and a loaded robot is why its aisle is shut
            var box = Math.max(4, Math.round(size * 0.46));
            var bx = Math.round((size - box) / 2);
            var by = Math.max(0, Math.round(size * 0.06));
            c.fillStyle = 'rgba(8,5,3,0.55)';
            c.fillRect(bx + 1, by + 1, box, box);
            c.fillStyle = '#8a6a45';
            c.fillRect(bx, by, box, box);
            c.strokeStyle = '#efe0c4';
            c.lineWidth = 1;
            c.strokeRect(bx + 0.5, by + 0.5, box - 1, box - 1);
          }
          kit[s][f][loaded] = surface;
        }
      }
    }
    return kit;
  }

  function bakeCrates(bitmap, tint) {
    // Shelf crates, baked from the starter's wall/crate texture at the three
    // chip sizes, tinted through the palette colour, with a 1 px rim.
    var crates = [];
    for (var s = 0; s < CHIP_SIZES.length; s++) {
      var size = CHIP_SIZES[s];
      var surface = createCanvasSurface();
      surface.width = size;
      surface.height = size;
      var c = surface.getContext('2d');
      if (bitmap) {
        c.drawImage(bitmap, 0, 0, bitmap.width, bitmap.height, 0, 0, size, size);
        c.globalCompositeOperation = 'multiply';
        c.fillStyle = tint;
        c.fillRect(0, 0, size, size);
        c.globalCompositeOperation = 'source-over';
      } else {
        c.fillStyle = tint;
        c.fillRect(0, 0, size, size);
      }
      c.strokeStyle = 'rgba(20,13,8,0.85)';
      c.lineWidth = 1;
      c.strokeRect(0.5, 0.5, size - 1, size - 1);
      crates[s] = surface;
    }
    return crates;
  }

  function samplePalette(bitmap) {
    if (!bitmap) return '#b98d57';
    try {
      var surface = createCanvasSurface();
      surface.width = bitmap.width;
      surface.height = bitmap.height;
      var c = surface.getContext('2d');
      c.drawImage(bitmap, 0, 0);
      var px = c.getImageData(Math.min(4, bitmap.width - 1),
        Math.min(4, bitmap.height - 1), 1, 1).data;
      return 'rgb(' + px[0] + ',' + px[1] + ',' + px[2] + ')';
    } catch (error) {
      return '#b98d57';
    }
  }

  function BroadcastCore(config) {
    var canvas = config.canvas;
    var onText = config.onText || function () {};
    var onStatus = config.onStatus || function () {};
    var onFirstFrame = config.onFirstFrame || function () {};
    var onTransform = config.onTransform || function () {};
    var onSendPacket = config.onSendPacket || null;

    var ctx = canvas ? canvas.getContext('2d') : null;
    var viewport = {
      width: config.viewportWidth || 1,
      height: config.viewportHeight || 1,
      dpr: config.devicePixelRatio || 1
    };
    var state = null;
    var firstFrameSent = false;
    var running = false;
    var socket = null;
    var draws = 0;
    var pulse = 0;
    var flashes = [];         // {x, y, age}
    var tiny = false;
    var chips = [null, null, null, null];
    var crates = null;
    var floorBitmap = null;
    var floorBake = null;
    var floorBakeKey = '';
    var assetsReady = false;
    var transform = {
      scale: 1, offsetX: 0, offsetY: 0, nativeW: 1, nativeH: 1,
      zoom: 1, minZoom: 1, maxZoom: 1, fitScale: 1,
      focusX: 0, focusY: 0, visW: 1, visH: 1
    };

    // ---- the feed queue -----------------------------------------------------
    // Kept for its SHAPE, not for rows of its own: pushFeed's signature is
    // load-bearing because a drift in it threw mid-replay and latched the
    // static adapter into `failed` with the scrubber still seekable, so every
    // static gate passed (cogball 0.1.4), and getPaceStats().queued reports
    // this queue's depth to `static_replay.js`. The rows the spectator reads
    // are DOM, built by the appended game block.
    var paceQueue = [];
    function pushFeed(text) {
      if (text === undefined || text === null) return;
      paceQueue.push({ text: String(text) });
      while (paceQueue.length > 64) paceQueue.shift();
    }
    function drainFeed() {
      while (paceQueue.length) onText(paceQueue.shift().text);
    }

    function loadAssets() {
      function optional(name) {
        return loadBitmap(name).catch(function () { return null; });
      }
      return Promise.all([
        optional('soldier_red.png'),
        optional('soldier_blue.png'),
        optional('soldier_green.png'),
        optional('soldier_yellow.png'),
        optional('arena_floor.png'),
        optional('wall_h.jpg'),
        optional('pallete.png')
      ]).then(function (all) {
        for (var i = 0; i < 4; i++) {
          chips[i] = bakeRobotChips(all[i], SEAT_COLOURS[i]);
        }
        floorBitmap = all[4];
        crates = bakeCrates(all[5], samplePalette(all[6]));
        assetsReady = true;
      });
    }

    function setViewportSize(width, height, dpr) {
      viewport.width = Math.max(1, width || 1);
      viewport.height = Math.max(1, height || 1);
      viewport.dpr = dpr || viewport.dpr || 1;
      tiny = viewport.width <= 620;
      if (canvas) {
        canvas.width = Math.round(viewport.width * viewport.dpr);
        canvas.height = Math.round(viewport.height * viewport.dpr);
      }
      floorBakeKey = '';
      draw();
    }

    function board() {
      return (state && state.rw && state.rw.board) || { w: 10, h: 11 };
    }

    function boardGeometry() {
      var b = board();
      var w = canvas ? canvas.width : 1;
      var h = canvas ? canvas.height : 1;
      var cell = Math.max(1, Math.floor(Math.min(w / b.w, h / b.h)));
      var spanX = cell * b.w;
      var spanY = cell * b.h;
      return {
        cols: b.w,
        rows: b.h,
        cell: cell,
        spanX: spanX,
        spanY: spanY,
        left: Math.floor((w - spanX) / 2),
        top: Math.floor((h - spanY) / 2)
      };
    }

    function publishTransform(geo) {
      var next = {
        scale: geo.cell, offsetX: geo.left, offsetY: geo.top,
        nativeW: geo.spanX, nativeH: geo.spanY,
        zoom: 1, minZoom: 1, maxZoom: 1, fitScale: geo.cell,
        focusX: geo.cols / 2, focusY: geo.rows / 2,
        visW: geo.cols, visH: geo.rows
      };
      var changed = false;
      for (var key in next) {
        if (next[key] !== transform[key]) changed = true;
      }
      transform = next;
      if (changed) onTransform(transform);
    }

    function sizeIndexFor(cell) {
      return cell >= 24 ? 2 : (cell >= 15 ? 1 : 0);
    }

    // ---- drawWarehouse -------------------------------------------------------
    function bakeFloor(geo) {
      var b = board();
      var key = geo.spanX + 'x' + geo.spanY + 'x' + geo.cell;
      if (floorBakeKey === key && floorBake) return floorBake;
      var surface = createCanvasSurface();
      surface.width = geo.spanX;
      surface.height = geo.spanY;
      var fc = surface.getContext('2d');
      fc.fillStyle = '#241a12';
      fc.fillRect(0, 0, geo.spanX, geo.spanY);
      if (floorBitmap) {
        var tile = Math.max(32, floorBitmap.width);
        for (var y = 0; y < geo.spanY; y += tile) {
          for (var x = 0; x < geo.spanX; x += tile) {
            fc.drawImage(floorBitmap, x, y, tile, tile);
          }
        }
      }
      // darkened 18 %, so the crates, the chips and the chalk read against it
      fc.fillStyle = 'rgba(11,7,4,0.18)';
      fc.fillRect(0, 0, geo.spanX, geo.spanY);
      // the shelf-block shadow: every storage cell gets a recessed footprint,
      // so the aisle plan is legible even where a shelf has been carried away
      var storage = b.storage || [];
      fc.fillStyle = 'rgba(8,5,3,0.30)';
      for (var i = 0; i < storage.length; i++) {
        fc.fillRect(storage[i][0] * geo.cell, storage[i][1] * geo.cell,
          geo.cell, geo.cell);
      }
      // chalk aisle lines along every gridline
      fc.strokeStyle = 'rgba(242,232,216,0.08)';
      fc.lineWidth = 1;
      for (var gx = 1; gx < geo.cols; gx++) {
        var px = gx * geo.cell + 0.5;
        fc.beginPath(); fc.moveTo(px, 0); fc.lineTo(px, geo.spanY); fc.stroke();
      }
      for (var gy = 1; gy < geo.rows; gy++) {
        var py = gy * geo.cell + 0.5;
        fc.beginPath(); fc.moveTo(0, py); fc.lineTo(geo.spanX, py); fc.stroke();
      }
      // the two workstation pads: amber chalk boxes with their W1 / W2 letters
      var goals = b.goals || [];
      for (var g = 0; g < goals.length; g++) {
        var gxp = goals[g][0] * geo.cell;
        var gyp = goals[g][1] * geo.cell;
        fc.fillStyle = 'rgba(217,164,65,0.22)';
        fc.fillRect(gxp, gyp, geo.cell, geo.cell);
        fc.strokeStyle = AMBER;
        fc.lineWidth = 2;
        fc.strokeRect(gxp + 1, gyp + 1, geo.cell - 2, geo.cell - 2);
        if (geo.cell >= 12) {
          fc.fillStyle = AMBER;
          fc.font = Math.max(7, Math.round(geo.cell * 0.42)) + 'px monospace';
          fc.textAlign = 'center';
          fc.textBaseline = 'middle';
          fc.fillText('W' + (g + 1), gxp + geo.cell / 2, gyp + geo.cell / 2);
        }
      }
      // 1 px chalk border around the whole floor
      fc.strokeStyle = 'rgba(242,232,216,0.28)';
      fc.lineWidth = 1;
      fc.strokeRect(0.5, 0.5, geo.spanX - 1, geo.spanY - 1);
      floorBake = surface;
      floorBakeKey = key;
      return surface;
    }

    function drawWarehouse(geo) {
      ctx.drawImage(bakeFloor(geo), geo.left, geo.top);
      for (var i = flashes.length - 1; i >= 0; i--) {
        var mark = flashes[i];
        mark.age++;
        if (mark.age > FLASH_FRAMES) { flashes.splice(i, 1); continue; }
        ctx.fillStyle = 'rgba(120,220,140,' +
          (0.7 * (1 - mark.age / FLASH_FRAMES)).toFixed(2) + ')';
        ctx.fillRect(geo.left + mark.x * geo.cell, geo.top + mark.y * geo.cell,
          geo.cell, geo.cell);
      }
    }

    // ---- drawShelves ---------------------------------------------------------
    function drawShelves(geo) {
      var shelves = (state.rw && state.rw.shelves) || [];
      var kit = crates ? crates[sizeIndexFor(geo.cell)] : null;
      for (var i = 0; i < shelves.length; i++) {
        var s = shelves[i];
        var px = geo.left + s[0] * geo.cell;
        var py = geo.top + s[1] * geo.cell;
        if (kit) ctx.drawImage(kit, px, py, geo.cell, geo.cell);
        else {
          ctx.fillStyle = '#8a6a45';
          ctx.fillRect(px, py, geo.cell, geo.cell);
        }
        if (s[2]) {
          // a REQUESTED shelf wears a 2 px amber outline
          ctx.strokeStyle = AMBER;
          ctx.lineWidth = 2;
          ctx.strokeRect(px + 1, py + 1, geo.cell - 2, geo.cell - 2);
        }
      }
    }

    // ---- drawRequestRail -----------------------------------------------------
    // The rail itself is DOM, in the top band (the appended game block builds
    // it). What belongs on the BOARD is the id of every requested shelf that
    // is still standing, so a spectator can match a rail chip to a crate.
    function drawRequestRail(geo) {
      if (geo.cell < 15) return;
      var requests = (state.rw && state.rw.requests) || [];
      ctx.font = Math.max(7, Math.round(geo.cell * 0.34)) + 'px monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'bottom';
      for (var i = 0; i < requests.length; i++) {
        var r = requests[i];
        if (r.by >= 0) continue;
        ctx.fillStyle = 'rgba(12,8,5,0.72)';
        ctx.fillRect(geo.left + r.x * geo.cell, geo.top + r.y * geo.cell,
          geo.cell, Math.round(geo.cell * 0.38));
        ctx.fillStyle = AMBER;
        ctx.fillText(r.id, geo.left + (r.x + 0.5) * geo.cell,
          geo.top + r.y * geo.cell + Math.round(geo.cell * 0.36));
      }
    }

    // ---- drawRobots ----------------------------------------------------------
    function drawRobots(geo) {
      var robots = (state.rw && state.rw.robots) || [];
      var sizeIndex = sizeIndexFor(geo.cell);
      for (var slot = 0; slot < robots.length; slot++) {
        var r = robots[slot];
        var px = geo.left + r[0] * geo.cell;
        var py = geo.top + r[1] * geo.cell;
        var kit = chips[slot % 4];
        var loaded = r[3] >= 0 ? 1 : 0;
        if (kit) {
          ctx.drawImage(kit[sizeIndex][r[2] % 4][loaded], px, py,
            geo.cell, geo.cell);
        } else {
          ctx.fillStyle = SEAT_COLOURS[slot % 4];
          ctx.fillRect(px, py, geo.cell, geo.cell);
        }
      }
    }

    // ---- drawJam -------------------------------------------------------------
    function drawJam(geo) {
      var jam = (state.rw && state.rw.jam) || null;
      if (!jam || !jam.on) return;
      var alpha = 0.45 + 0.35 * Math.abs(Math.sin(pulse / 7));
      var cells = jam.cells || [];
      for (var i = 0; i < cells.length; i++) {
        var cx = geo.left + (cells[i][0] + 0.5) * geo.cell;
        var cy = geo.top + (cells[i][1] + 0.5) * geo.cell;
        ctx.strokeStyle = 'rgba(224,82,58,' + alpha.toFixed(2) + ')';
        ctx.lineWidth = Math.max(2, Math.round(geo.cell / 8));
        ctx.beginPath();
        ctx.arc(cx, cy, geo.cell * 0.52, 0, Math.PI * 2);
        ctx.stroke();
        // the contested cell wears a red cross
        var arm = geo.cell * 0.28;
        ctx.beginPath();
        ctx.moveTo(cx - arm, cy - arm); ctx.lineTo(cx + arm, cy + arm);
        ctx.moveTo(cx + arm, cy - arm); ctx.lineTo(cx - arm, cy + arm);
        ctx.stroke();
      }
    }

    function draw() {
      if (!ctx || !state) return;
      pulse++;
      var geo = boardGeometry();
      publishTransform(geo);
      ctx.fillStyle = '#120d09';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      drawWarehouse(geo);
      drawShelves(geo);
      drawRequestRail(geo);
      drawRobots(geo);
      drawJam(geo);
      draws++;
    }

    function ingest(bytes) {
      var text;
      if (typeof bytes === 'string') text = bytes;
      else text = new TextDecoder('utf-8').decode(bytes);
      var next;
      try {
        next = JSON.parse(text);
      } catch (error) {
        throw new Error('state frame is not JSON: ' + error.message);
      }
      state = next;
      var goals = (state.rw && state.rw.board && state.rw.board.goals) || [];
      var deliveries = (state.rw && state.rw.deliveries) || [];
      for (var i = 0; i < deliveries.length; i++) {
        var pad = goals[deliveries[i].station] || null;
        if (pad) flashes.push({ x: pad[0], y: pad[1], age: 0 });
      }
      while (flashes.length > 64) flashes.shift();
      // The visible feed is DOM, built by the appended game block from this
      // same `rw.events` array (client/game_block.html). The core formats no
      // rows of its own: the page's onText IS its JSON frame parser, so a
      // plain-text row handed to it is parsed, fails and is dropped. One
      // vocabulary, in one place.
      onText(text);
      drainFeed();
      draw();
      if (!firstFrameSent) {
        firstFrameSent = true;
        onFirstFrame();
      }
    }

    function sendCommand(textCommand) {
      if (onSendPacket) {
        onSendPacket(new TextEncoder().encode(String(textCommand)));
        return;
      }
      if (socket && socket.readyState === 1) socket.send(String(textCommand));
    }

    function connect() {
      var url = config.websocket;
      if (typeof url !== 'string' || !url.length) return;
      onStatus('connecting');
      socket = new WebSocket(url);
      socket.onopen = function () { onStatus('open'); };
      socket.onclose = function () { onStatus('closed'); };
      socket.onerror = function () { onStatus('closed'); };
      socket.onmessage = function (event) {
        if (typeof event.data === 'string') ingest(event.data);
      };
    }

    function tick() {
      if (!running) return;
      draw();
      requestFrame(tick);
    }

    function start() {
      if (running) return;
      running = true;
      loadAssets().then(function () {
        draw();
        // The static bundle has no socket, so nothing would ever move the
        // status chip off 'connecting' and the featured match would show
        // CONNECTING over a playing replay for the whole episode. Assets baked
        // and the first frame drawn IS this delivery mode's 'open'.
        if (!config.websocket) onStatus('open');
      });
      if (config.websocket) connect();
      requestFrame(tick);
    }

    function stop() {
      running = false;
      if (socket) { try { socket.close(); } catch (e) {} socket = null; }
    }

    return {
      start: start,
      stop: stop,
      ingest: ingest,
      sendCommand: sendCommand,
      clickMap: function () {},
      // Zoom and pan are NO-OPS by design: the board is a fixed grid that
      // relayout() fits whole at every width, so #viewpanel is dropped. The
      // methods stay so the static adapter's API surface is unchanged.
      zoomAt: function () {},
      setZoom: function () {},
      panBy: function () {},
      panByMap: function () {},
      panTo: function () {},
      resetView: function () {},
      attachMinimap: function () {},
      getTransform: function () { return transform; },
      setViewportSize: setViewportSize,
      setViewportFit: function () { draw(); },
      getState: function () { return state; },
      getPaceStats: function () {
        return {
          enabled: false, queued: paceQueue.length, presented: 0,
          interval: 1000 / FPS, draws: draws
        };
      },
      assetsReady: function () { return assetsReady; },
      SEAT_COLOURS: SEAT_COLOURS,
      SEAT_NAMES: SEAT_NAMES,
      SPEEDS: SPEEDS
    };
  }

  globalScope.BroadcastCore = { create: BroadcastCore };
})();
