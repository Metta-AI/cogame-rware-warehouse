## Replay playback: the frame driver, the per-tick hash check, the transport
## commands, and the load-time PRE-SCAN that lets the deliveries sparkline and
## the scrubber beats draw at full width on the very first frame.
##
## The driver is `sim.advanceFrame` -- the SAME proc the live server loop calls
## -- and every fact that cannot be re-derived from sim state (the game start,
## a wall-clock stop) is a recorded record applied by the same proc on both
## sides. That is what keeps the chain clean at the stop tick.

import std/[json, strutils]
import sim, replays

const
  TicksPerSecondBase* = TargetFps
    ## Playback rate at speed 1: ONE sim tick per animation frame at 30 fps,
    ## advanced by an integer accumulator against TargetFps. A 500-tick episode
    ## therefore plays for 16.7 s, which is what lets `viewer_smoke.mjs
    ## --soak 10` observe real advancement instead of a legitimately-finished
    ## replay (the ecos 2026-08-23 scar).
  LullTicks* = 40
    ## A lull is this many consecutive ticks with no load, deliver, stow or jam.
  ReplayHalfSpeedIndex* = -1
    ## The half-speed chip's `speedIndex`, a SENTINEL rather than a
    ## `PlaybackSpeeds` entry: index 0 stays 1x -- the speed every replay opens
    ## at -- and the whole-number multipliers keep their '1'/'2'/'4'/'8'
    ## command chars. Half speed needs no new arithmetic either: the
    ## accumulator in `advanceReplayFrame` is already a rate over `TargetFps`,
    ## so adding half a frame's worth lands one sim tick every OTHER frame.

type
  Beat* = object
    tick*: int
    kind*: string
    side*: string
    label*: string

  ReplayPlayer* = object
    data*: ReplayData
    frame*: int
    maxFrame*: int
    playing*: bool
    looping*: bool
    skipLulls*: bool
    speedIndex*: int
    accumulator*: int
    hashMismatchTick*: int
    mismatchQuit*: bool
    orderCursor*: int
    chatCursor*: int
    startCursor*: int
    stopCursor*: int
    feed*: seq[ChatRecord]
    pending*: seq[ChatRecord]
    lulls*: seq[array[2, int]]
    beats*: seq[Beat]
    deliverySeries*: seq[array[2, int]]   ## frame, cumulative deliveries
    jamSpans*: seq[array[2, int]]
    gameStartFrames*: seq[int]
    scanned*: bool
    fastForward*: bool

  InitializedReplay* = object
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer

proc playbackSpeed*(player: ReplayPlayer): int =
  PlaybackSpeeds[clamp(player.speedIndex, 0, PlaybackSpeeds.high)]

proc halfSpeed*(player: ReplayPlayer): bool =
  player.speedIndex == ReplayHalfSpeedIndex

proc replayDisplaySpeed*(player: ReplayPlayer): float =
  ## The speed the chrome highlights a chip against (`sp` on the wire). A
  ## float, because half speed has no integer to report.
  if player.halfSpeed: 0.5 else: player.playbackSpeed().float

proc startFrame*(player: ReplayPlayer): int =
  ## The first game-start frame. Everything before it is the recorded pre-game
  ## lobby (seats joining, LLM registration) with the board frozen at tick 0.
  ## The scrubber axis already begins here (`st` in buildStateJson), so
  ## playback opens here and every seek clamps here -- dwelling on the lobby
  ## held the hosted viewer on its first tick for gameStarts[0].tick / 6
  ## seconds (~40 s on a real ladder episode) before anything moved.
  if player.gameStartFrames.len > 0:
    min(player.gameStartFrames[0], player.maxFrame)
  else:
    0

proc resetCursors(player: var ReplayPlayer) =
  player.frame = 0
  player.orderCursor = 0
  player.chatCursor = 0
  player.startCursor = 0
  player.stopCursor = 0
  player.accumulator = 0
  player.feed = @[]
  player.pending = @[]

proc configFromReplay*(data: ReplayData): GameConfig =
  result = defaultGameConfig()
  result.update(data.configJson)

proc runFrame(player: var ReplayPlayer, sim: var SimServer) =
  ## Applies every record stamped with the current frame, advances the sim by
  ## one frame, then checks the recorded hash.
  player.pending = @[]
  while player.startCursor < player.data.gameStarts.len and
      player.data.gameStarts[player.startCursor].tick == player.frame:
    sim.applyGameStart()
    inc player.startCursor
  while player.orderCursor < player.data.orders.len and
      player.data.orders[player.orderCursor].tick == player.frame:
    let record = player.data.orders[player.orderCursor]
    if record.slot >= 0 and record.slot < SeatCount:
      var directive = sim.directives[record.slot]
      directive.order = record.order
      directive.source = dsScripted
      sim.applyOrders(record.slot, directive)
      sim.turnIndex = record.turn
    inc player.orderCursor
  while player.stopCursor < player.data.stops.len and
      player.data.stops[player.stopCursor].tick == player.frame:
    sim.applyStop(player.data.stops[player.stopCursor].endRule)
    inc player.stopCursor
  while player.chatCursor < player.data.chats.len and
      player.data.chats[player.chatCursor].tick == player.frame:
    player.pending.add(player.data.chats[player.chatCursor])
    player.feed.add(player.data.chats[player.chatCursor])
    inc player.chatCursor
  sim.advanceFrame()
  var recorded = -1
  for i in 0 ..< player.data.hashes.len:
    if player.data.hashes[i].tick == player.frame:
      recorded = i
      break
  if recorded >= 0 and player.hashMismatchTick < 0:
    if sim.gameHash() != player.data.hashes[recorded].value:
      player.hashMismatchTick = player.frame
      if player.mismatchQuit:
        raise newException(ReplayError,
          "replay hash mismatch at tick " & $player.frame)
  inc player.frame

proc scanReplay(player: var ReplayPlayer, config: GameConfig) =
  ## The load-time pre-scan: re-simulate the whole episode once headlessly,
  ## recording the cumulative deliveries, the jam spans, the lull spans and the
  ## beat ticks. Integer work over 500 frames -- single-digit milliseconds in
  ## wasm -- and it is what lets the sparkline and the scrubber beats draw at
  ## FULL WIDTH on the first frame instead of growing in.
  var sim = initSimServer(config)
  player.resetCursors()
  player.hashMismatchTick = -1
  var
    lastEventFrame = 0
    jamOpen = -1
  player.beats = @[]
  player.deliverySeries = @[]
  player.jamSpans = @[]
  player.lulls = @[]
  player.gameStartFrames = @[]
  for record in player.data.gameStarts:
    player.gameStartFrames.add(record.tick)
  while player.frame <= player.maxFrame:
    let frame = player.frame
    runFrame(player, sim)
    player.deliverySeries.add([frame, sim.teamDelivered()])
    if sim.lastDeliveries.len > 0 or sim.lastLoads.len > 0 or
        sim.lastStows.len > 0 or sim.jamState.active:
      lastEventFrame = frame
    for mark in sim.lastDeliveries:
      player.beats.add(Beat(
        tick: frame, kind: "delivery",
        side: (if mark.slot >= 0: seatAliasName(mark.slot).toLowerAscii()
               else: ""),
        label: shelfLabel(mark.shelf) & " delivered to " &
          stationLabel(mark.station) & " - " & $sim.teamDelivered() &
          " so far"))
    ## Clear first: a jam whose membership changed closes its span and opens a
    ## new one on the SAME frame, so a scrubber never shows two overlapping
    ## jam spans and never loses the marker for the jam that is still running.
    if sim.jamCleared and jamOpen >= 0:
      player.jamSpans.add([jamOpen, frame])
      jamOpen = -1
    if sim.jamStarted and jamOpen < 0:
      jamOpen = frame
      var who: seq[string]
      for slot in sim.jamState.members:
        who.add(seatAliasName(slot).toUpperAscii())
      player.beats.add(Beat(
        tick: frame, kind: "jam", side: "",
        label: "Jam - " & who.join(" and ")))
    if frame - lastEventFrame >= LullTicks:
      if player.lulls.len > 0 and player.lulls[^1][1] >= lastEventFrame:
        player.lulls[^1][1] = frame
      else:
        player.lulls.add([lastEventFrame + 1, frame])
    if sim.phase == GameOver and sim.gameOverHold == 1:
      player.beats.add(Beat(
        tick: frame, kind: "end", side: "",
        label: $sim.teamDelivered() & " shelves delivered - " & sim.endRule))
  if jamOpen >= 0:
    player.jamSpans.add([jamOpen, player.maxFrame])
  for record in player.data.chats:
    if record.text.len > 0 and record.text[0] == '{' and
        "\"k\":\"fallback\"" in record.text:
      player.beats.add(Beat(
        tick: record.tick, kind: "fallback", side: "",
        label: "A driver missed the call - scripted order"))
  player.scanned = true

proc initReplayRuntime*(
  data: ReplayData, mismatchQuit = false
): InitializedReplay =
  result.config = configFromReplay(data)
  result.player.data = data
  result.player.maxFrame = max(0, data.frameCount - 1)
  result.player.mismatchQuit = mismatchQuit
  result.player.hashMismatchTick = -1
  result.player.playing = true
  result.player.speedIndex = 0
  scanReplay(result.player, result.config)
  result.player.resetCursors()
  result.player.hashMismatchTick = -1
  result.sim = initSimServer(result.config)
  while result.player.frame <= result.player.startFrame:
    runFrame(result.player, result.sim)

proc seekTo*(player: var ReplayPlayer, sim: var SimServer, frame: int) =
  ## Seeks by re-simulating from frame 0. Five hundred integer frames is
  ## microseconds, so a fresh re-derivation is both the simplest and the most
  ## trustworthy seek: the state a viewer scrubs to is always the state the
  ## recorded orders produce.
  let target = clamp(frame, player.startFrame, player.maxFrame)
  let keepMismatch = player.hashMismatchTick
  player.resetCursors()
  player.hashMismatchTick = -1
  sim = initSimServer(sim.config)
  while player.frame <= target:
    runFrame(player, sim)
  if player.hashMismatchTick < 0:
    player.hashMismatchTick = keepMismatch

proc applyCommand*(
  player: var ReplayPlayer, sim: var SimServer, command: string
) =
  ## The transport. Plain single chars from the shared chrome, plus `s:<tick>`
  ## from the scrubber and the labelled beat buttons.
  if command.len == 0:
    return
  if command.startsWith("s:"):
    try:
      player.seekTo(sim, parseInt(command[2 .. ^1].strip()))
    except CatchableError:
      discard
    return
  case command[0]
  of ' ': player.playing = not player.playing
  of 'b': player.seekTo(sim, player.frame - 2)
  of ',': player.seekTo(sim, 0)
  of '.': player.seekTo(sim, player.frame + 5 * TicksPerSecondBase)
  of 'e': player.seekTo(sim, player.maxFrame)
  of 'r': player.looping = not player.looping
  of 'f': player.skipLulls = not player.skipLulls
  # The speed chars are VALUES, not indices: '5' is the half-speed chip (the
  # 5 of 0.5), the rest are the multipliers themselves.
  of '5': player.speedIndex = ReplayHalfSpeedIndex
  of '1': player.speedIndex = 0
  of '2': player.speedIndex = 1
  of '4': player.speedIndex = 2
  of '8': player.speedIndex = 3
  else: discard

proc inLull(player: ReplayPlayer, frame: int): bool =
  for span in player.lulls:
    if frame >= span[0] and frame <= span[1]:
      return true
  false

proc advanceReplayFrame*(
  player: var ReplayPlayer, sim: var SimServer
) =
  ## One presentation frame. Bounded: at most a handful of sim frames run per
  ## call even when skipping a lull, so a slow browser can never be starved by
  ## the runtime.
  player.fastForward = false
  if not player.playing:
    return
  if player.frame > player.maxFrame:
    if player.looping:
      player.seekTo(sim, 0)
    return
  let framePace =
    if player.halfSpeed: TicksPerSecondBase div 2
    else: player.playbackSpeed() * TicksPerSecondBase
  player.accumulator += framePace
  var advanced = 0
  while player.accumulator >= TargetFps and advanced < 8:
    player.accumulator -= TargetFps
    if player.frame > player.maxFrame:
      break
    runFrame(player, sim)
    inc advanced
  if player.skipLulls and player.inLull(player.frame):
    player.fastForward = true
    var skipped = 0
    while player.frame <= player.maxFrame and player.inLull(player.frame) and
        skipped < 64:
      runFrame(player, sim)
      inc skipped

proc beatsJson*(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for beat in player.beats:
    result.add(%*{
      "t": beat.tick, "k": beat.kind, "side": beat.side, "label": beat.label})

proc lullsJson*(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for span in player.lulls:
    result.add(%[span[0], span[1]])

proc jamSpansJson*(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for span in player.jamSpans:
    result.add(%[span[0], span[1]])

proc leadJson*(player: ReplayPlayer): JsonNode =
  ## The deliveries sparkline: ONE cumulative series over the whole episode, in
  ## the shape chrome_common's momentum graph reads (`{teams, pts}` with
  ## pts = [tick, a, b]). The second series is a flat zero, so the graph's
  ## two-team diff branch draws the cumulative delivery count as a green step
  ## line climbing away from the midline.
  var pts = newJArray()
  var last = -1
  for sample in player.deliverySeries:
    if sample[1] == last:
      continue
    last = sample[1]
    pts.add(%[sample[0], sample[1], 0])
  %*{"teams": ["green", "red"], "pts": pts}
