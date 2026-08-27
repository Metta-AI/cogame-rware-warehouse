## The viewer's static contract: chrome provenance, the removed elements, the
## beat kinds, the transport rules and the 360 px rules.
##
## Nothing here opens a browser -- `ci.yml`'s `wasm-viewer` job does that with
## `tools/ci/viewer_smoke.mjs`. These are the assertions that must hold on the
## SOURCE, where a rewrite of inherited chrome is visible and a browser smoke
## would go green over it.

import std/[algorithm, sequtils, strutils, unittest]
import helpers
import crunchy

const
  StarterChromeSha =
    "7ace7287e0d19bf0fddb2362c55e4d76dfb44adcd4fbc8d1743b0557ced72f7c"
    ## coworld-ctf/client/chrome_common.js, byte for byte. Everything this game
    ## adds lives in the appended game block; the shared chrome is not edited,
    ## not reformatted and not "tidied".
  SpliceMarker = "RWARE-WAREHOUSE additions to the inherited coworld-ctf chrome"
  RemovedIds = ["#viewpanel", "#minimap", "#minimap-canvas", "#zoombar",
                "#zoom-in", "#zoom-out", "#zoom-slider", "#zoom-read",
                "#fpv", "#fpv-canvas", "#fpv-hud", "#fpv-name", "#fpv-hp",
                "#fpv-gear", "#fpv-map", "#fpv-map-canvas", "#fpv-cap",
                "#fpv-grip", "#povBadge"]
  KeptIds = ["viewport", "stage", "board", "lightpool", "grain", "lockerroom",
             "lk-bg", "lk-art", "lk-sprites", "lk-cap", "chrome", "scorebug",
             "plates-l", "plates-r", "clock", "clock-time", "clock-caption",
             "bannerlane", "killfeed", "mmwarn", "transport", "btn-restart",
             "btn-back", "btn-play", "btn-fwd", "btn-end", "btn-loop",
             "btn-skip", "btn-spoilers", "ffwd-chip", "ffwd-mini", "win-chip",
             "tick-clock", "speedchips", "scrub", "momentum", "scrub-fill",
             "lulls", "scrub-win", "scrub-head", "endcard", "ec-headline",
             "ec-wincond", "ec-how", "ec-teams", "ec-replay", "status"]
  EmittedBeatKinds = ["delivery", "jam", "fallback", "end"]

proc page(): string = readRepoFile("client/replay_broadcast.html")
proc gameBlock(): string = readRepoFile("client/game_block.html")
proc pageScript(): string = readRepoFile("client/page_script.js")
proc core(): string = readRepoFile("client/broadcast_core.js")

proc withoutComments(text: string): string =
  ## HTML, CSS and `#`/`//` line comments removed. A comment explaining what
  ## was deleted -- or naming the trap a rename avoids -- is documentation; a
  ## live token is code, and only the latter is under test.
  var body = text
  for (opener, closer) in [("<!--", "-->"), ("/*", "*/")]:
    var scan = 0
    while true:
      let start = body.find(opener, scan)
      if start < 0:
        break
      let stop = body.find(closer, start)
      if stop < 0:
        body = body[0 ..< start]
        break
      body = body[0 ..< start] & body[stop + closer.len .. ^1]
      scan = start
  var lines: seq[string]
  for line in body.splitLines():
    var cut = -1
    for marker in ["//", "#"]:
      let at = line.find(marker)
      if at >= 0 and line[0 ..< at].count('"') mod 2 == 0 and
          line[0 ..< at].count('\'') mod 2 == 0 and (cut < 0 or at < cut):
        cut = at
    lines.add(if cut >= 0: line[0 ..< cut] else: line)
  lines.join("\n")

proc styleBlocks(text: string): string =
  var scan = 0
  while true:
    let open = text.find("<style>", scan)
    if open < 0:
      break
    let close = text.find("</style>", open)
    if close < 0:
      break
    result.add(text[open + "<style>".len ..< close])
    scan = close

suite "rware viewer":

  test "chrome_common is byte-identical to the starter's":
    ## 30. Pinned as a literal so an edit -- even a reformat -- is a red test
    ##     rather than a silently diverged copy of shared chrome.
    let digest = sha256(readRepoFile("client/chrome_common.js")).toHex()
    check digest.toLowerAscii() == StarterChromeSha

  test "the broadcast page is the starter's page plus an appended block":
    ## 31. The starter's bytes come first, the splice marker is present exactly
    ##     once, and everything this game adds is after it.
    let text = page()
    check text.count(SpliceMarker) == 1
    let at = text.find(SpliceMarker)
    let inherited = text[0 ..< at]
    ## the inherited half still carries the starter's own structure
    for marker in ["<!DOCTYPE html>", "<!-- WIRE_CONSTANTS -->",
                   "<!-- CHROME_COMMON -->", "id=\"viewport\"",
                   "id=\"transport\"", "id=\"scrub\"", "id=\"endcard\"",
                   "function relayout()"]:
      if marker notin inherited:
        checkpoint("the inherited half lost " & marker)
        fail()
    ## and the appended half is where every game-specific name lives
    let appended = text[at .. ^1]
    for marker in ["warehouseBeat", "RwareChrome", "#reqrail", "#jamchip",
                   ".beat-marker.delivery"]:
      check marker in appended
    ## the builder script that produced it is committed, so the fork is
    ## reproducible rather than a hand-edited 4,000-line page
    check repoFileExists("tools/build_broadcast_page.py")
    check "--starter" in readRepoFile("tools/build_broadcast_page.py")

  test "no shadowed chrome aliases":
    ## 32. The chrome alias block declares its names with hoisted `var`s; a
    ##     game-block function of the same name is silently swallowed and the
    ##     scrubber ends up with unlabelled div markers that never seek
    ##     (cogame-tandem, 2026-08-23).
    var aliases: seq[string]
    for line in pageScript().splitLines():
      let trimmed = line.strip()
      if not trimmed.startsWith("var ") or " = C." notin trimmed:
        continue
      for part in trimmed[4 .. ^1].split(','):
        let name = part.split('=')[0].strip()
        if name.len > 0 and name notin aliases:
          aliases.add(name)
    check aliases.len > 10
    check "markBeat" in aliases
    let block1 = withoutComments(gameBlock())
    for alias in aliases:
      for form in ["function " & alias & "(", "var " & alias & " =",
                   "let " & alias & " =", "const " & alias & " ="]:
        if form in block1:
          checkpoint("the game block re-declares the chrome alias " & alias)
          fail()
    ## the beat builder is warehouseBeat, never markBeat
    check "function warehouseBeat(" in block1
    check "markBeat" notin block1

  test "beat CSS matches exactly the kinds the sim emits":
    ## 33. A kind with no CSS renders as an unstyled div; a rule for a kind the
    ##     sim never emits is dead paint.
    let styles = styleBlocks(page())
    var declared: seq[string]
    var scan = 0
    const needle = ".beat-marker."
    while true:
      let at = styles.find(needle, scan)
      if at < 0:
        break
      scan = at + needle.len
      var name = ""
      var i = scan
      while i < styles.len and styles[i] in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}:
        name.add(styles[i])
        inc i
      if name.len > 0 and name notin declared:
        declared.add(name)
    declared.sort()
    var want = @EmittedBeatKinds
    want.sort()
    check declared == want
    ## and the pre-scan only ever emits those kinds
    let runtime = stripNimComments(readRepoFile("src/rware/replay_runtime.nim"))
    var emitted: seq[string]
    var cursor = 0
    const marker = "kind: \""
    while true:
      let at = runtime.find(marker, cursor)
      if at < 0:
        break
      cursor = at + marker.len
      let stop = runtime.find('"', cursor)
      let name = runtime[cursor ..< stop]
      if name notin emitted:
        emitted.add(name)
    emitted.sort()
    check emitted == want

  test "transport, endcard and the removed elements":
    ## 34. relayout() owns --band / --topband / --hudscale on :root; the
    ##     endcard stops at var(--band); every seek dismisses it; and the
    ##     removed ids appear nowhere outside the banner comment.
    let text = page()
    check "#endcard { bottom: var(--band" in text or
      "bottom: var(--band, 0px)" in text
    for property in ["--band", "--topband", "--hudscale"]:
      check "root.style.setProperty('" & property & "'" in text
    check "classList.remove('on')" in text
    ## the removed ids: only the banner comment may name them
    let at = text.find(SpliceMarker)
    let bannerEnd = text.find("-->", at)
    let scrubbed = text[0 ..< at] & text[bannerEnd .. ^1]
    for id in RemovedIds:
      if id in scrubbed:
        let where = scrubbed.find(id)
        checkpoint("the removed element " & id & " survives: ..." &
          scrubbed[max(0, where - 70) ..< min(scrubbed.len, where + 40)]
            .replace("\n", " ") & "...")
        fail()
      if "id=\"" & id[1 .. ^1] & "\"" in text:
        checkpoint("the removed element " & id & " still has markup")
        fail()
    ## and every kept id is still there
    for id in KeptIds:
      if "id=\"" & id & "\"" notin text:
        checkpoint("the inherited element #" & id & " went missing")
        fail()

  test "nothing the game block adds sits inside the transport band":
    ## The board is laid out between the two bands; the request rail and the
    ## jam chip are in the TOP band, anchored to #chrome, never to #transport.
    let block1 = gameBlock()
    for id in ["#reqrail", "#jamchip"]:
      let at = block1.find(id & " {")
      check at >= 0
      let rule = block1[at ..< block1.find("}", at)]
      check "top:" in rule
      check "bottom:" notin rule
    check "chrome.appendChild(rail)" in block1
    check "chrome.appendChild(jam)" in block1

  test "the three 360 px rules":
    let text = page()
    ## 1. a policy name never collapses to a bare ellipsis
    check ".plate-name {" in text
    let at = text.find(".plate-name {")
    let rule = text[at ..< text.find("}", at)]
    check "flex: 1 1 auto" in rule
    check "min-width: 3.2em" in rule
    check "overflow: hidden" in rule
    check "text-overflow: ellipsis" in rule
    ## 2. under .tiny each plate keeps only alias + name + delivered
    check "#stage.tiny .plate .deliv-label { display: none; }" in text
    check "#stage.tiny .plate .colour-chip" in text
    check "#stage.tiny .plate .fb-glyph" in text
    ## 3. under .tiny the rail shows shelf ids only
    check "#stage.tiny .req-chip .req-at" in text
    check "#stage.tiny #jamchip .jam-who" in text
    ## and relayout still toggles .tiny off the BOARD width
    check "classList.toggle('tiny', boardW < 640)" in pageScript()
    check "Math.max(0.5, Math.min(1.6, boardW / 760))" in pageScript()

  test "the board renderer draws chips, not names":
    ## The two name spaces, in the renderer: the board layer never sees a real
    ## policy name. Spectator-side names live in the DOM scorebug only.
    let text = core()
    check "seat.name" notin text
    check "roster" notin text
    check "drawWarehouse" in text
    check "drawShelves" in text
    check "drawRobots" in text
    check "drawJam" in text
    check "drawRequestRail" in text
    ## real art from the starter's shipped assets, no solid-colour placeholder
    for asset in ["soldier_red.png", "soldier_blue.png", "soldier_green.png",
                  "soldier_yellow.png", "arena_floor.png", "wall_h.jpg",
                  "pallete.png"]:
      check asset in text
    ## and the chips are BAKED once, not rasterised per robot per frame
    check "bakeRobotChips" in text
    check "bakeCrates" in text
    check "bakeFloor" in text

  test "the static adapter and the worker are one matched set":
    ## The emscripten link flags and the JS bootstrap are a matched pair:
    ## paintbot-lineage shells wait for Module.onRuntimeInitialized and the
    ## module is emitted NON-modularized. A mixture hangs on "Loading replay"
    ## forever with nothing thrown and nothing logged (cogame-lantern).
    let config = withoutComments(readRepoFile("replay-viewer/config.nims"))
    let worker = readRepoFile("replay-viewer/static_replay_worker.js")
    let adapter = readRepoFile("replay-viewer/static_replay.js")
    check "MODULARIZE" notin config
    check "EXPORT_NAME" notin config
    check "Module.onRuntimeInitialized" in worker
    check "-s ABORTING_MALLOC=1" in config
    check "-s ALLOW_MEMORY_GROWTH" in config
    check "-s ENVIRONMENT=web,worker,node" in config
    check "-s EXPORTED_RUNTIME_METHODS=HEAPU8" in config
    ## No --preload-file / FILESYSTEM: the bundle's art is FETCHED over HTTP by
    ## broadcast_core.js from the files Dockerfile.replay-viewer copies next to
    ## the worker, so packing a virtual filesystem into the wasm would ship
    ## every asset twice.
    check "--preload-file" notin config
    for fn in ["_main", "_malloc", "_free", "_rware_load_replay",
               "_rware_frame", "_rware_input", "_rware_packet_ptr",
               "_rware_packet_len", "_rware_mismatch_tick",
               "_rware_error_ptr", "_rware_error_len", "_rware_stage_ptr",
               "_rware_stage_len"]:
      check fn in config
    check "importScripts('./wire_constants.js', './broadcast_core.js', " &
      "'./rware_replay.js')" in worker
    ## the load and failure signals viewer_smoke.mjs reads
    check "'data-replay-loaded', 'true'" in adapter
    check "'data-replay-error'" in adapter
    ## and the attribute is set from the Worker's `loaded` branch, which is
    ## posted only AFTER ingestPacket() handed the core the first frame
    check "message.type === 'loaded'" in adapter
    check "ingestPacket();" in worker

  test "the wasm entry exports what the config declares":
    let entry = readRepoFile("replay-viewer/rware_replay.nim")
    for name in ["rware_load_replay", "rware_frame", "rware_input",
                 "rware_packet_ptr", "rware_packet_len", "rware_mismatch_tick",
                 "rware_error_ptr", "rware_error_len", "rware_stage_ptr",
                 "rware_stage_len"]:
      check "exportc: \"" & name & "\"" in entry
    ## the structure the starter's entry has, kept
    check "stampStage" in entry
    check "bytesFromPointer" in entry
    check "emscripten_exit_with_live_runtime" in entry
    ## and it re-simulates through the SAME sim module
    check "import rware/[broadcast, replay_runtime, replays, roster, sim]" in
      entry

  test "the bundle ships every asset the renderer fetches":
    let dockerfile = readRepoFile("Dockerfile.replay-viewer")
    for asset in ["soldier_red.png", "soldier_blue.png", "soldier_green.png",
                  "soldier_yellow.png", "arena_floor.png", "pallete.png",
                  "wall_h.jpg", "wall_v.jpg"]:
      check "replay-viewer/dist/" & asset in dockerfile
    check "art/lockerroom" in dockerfile
    ## the page must NOT carry script tags for the files the Worker
    ## importScripts
    check "! grep -q '<script src=\"./broadcast_core.js\"></script>'" in
      dockerfile
    check "! grep -q '<script src=\"./rware_replay.js\"></script>'" in
      dockerfile

  test "playback outlasts the viewer soak":
    ## ecos 2026-08-23: a replay shorter than the soak window legitimately ends
    ## mid-soak and the harness reports a frozen viewer. One sim tick per
    ## animation frame at 30 fps means 500 ticks play for 16.7 s.
    let ci = readRepoFile(".github/workflows/ci.yml")
    check "--soak 10" in ci
    let ticksPerSecond = TargetFps
    let seconds = 500 div ticksPerSecond
    check seconds >= 10
    check PlaybackSpeeds[0] == 1
