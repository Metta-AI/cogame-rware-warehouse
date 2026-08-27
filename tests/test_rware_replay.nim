## The replay: record, re-derive, and read back with no toolchain.

import std/[json, os, osproc, strutils, unicode, unittest]
import helpers
import rware/replay_runtime

proc recordEpisode(
  maxTicks = 200, seed = 42
): tuple[sim: SimServer, bytes: string] =
  var config = testConfig(maxTicks = maxTicks, seed = seed)
  let run = runScriptedEpisode(config)
  (run.sim, run.bytes)

proc rederive(bytes: string): InitializedReplay =
  ## mismatchQuit = true: a divergent hash RAISES at the tick it happens rather
  ## than being reported and played through. The load-time PRE-SCAN already
  ## re-simulates the whole episode under that rule, so a clean return means
  ## every tick agreed.
  initReplayRuntime(parseReplayBytes(bytes), mismatchQuit = true)

proc playOut(runtime: var InitializedReplay) =
  ## Runs the returned runtime to the last frame, so a test can compare the
  ## FINAL re-derived state against the recorded one.
  while runtime.player.frame <= runtime.player.maxFrame:
    runtime.player.advanceReplayFrame(runtime.sim)

suite "rware replay":

  test "record then re-derive, every end reason":
    ## 24. tickCap, wallClock AND fault: record an episode and re-derive it
    ##     from the bytes; identical hashes at every tick INCLUDING the stop
    ##     tick (the particle-worlds scar).
    block tickCap:
      let (sim, bytes) = recordEpisode()
      check sim.endRule == EndRuleTickCap
      var back = rederive(bytes)
      back.playOut()
      check back.player.hashMismatchTick == -1
      check back.sim.tick == sim.tick
      check back.sim.teamDelivered() == sim.teamDelivered()
      check back.sim.endRule == sim.endRule
    block wallClock:
      var config = testConfig(maxTicks = 400)
      var sim = initSimServer(config)
      var writer = openReplayWriter("", config.configJson())
      var state = initEpisodeState()
      var engine = scriptedEngine(config)
      for seat in 0 ..< SeatCount:
        sim.admitSeat(seat, "")
        writer.writeJoin(0, seat, seatAlias(seat), "")
      while sim.tick < 120 and not state.finished:
        discard state.runEpisodeFrame(sim, engine, writer, 0)
      discard state.runEpisodeFrame(
        sim, engine, writer, config.wallClockBudgetSeconds + 1)
      state.finishEpisode(sim, writer)
      check sim.endRule == EndRuleWallClock
      var back = rederive(writer.bytes())
      back.playOut()
      check back.player.hashMismatchTick == -1
      check back.sim.endRule == EndRuleWallClock
      check back.sim.teamDelivered() == sim.teamDelivered()
    block fault:
      var config = testConfig(maxTicks = 400)
      var sim = initSimServer(config)
      var writer = openReplayWriter("", config.configJson())
      var state = initEpisodeState()
      var engine = scriptedEngine(config)
      for seat in 0 ..< SeatCount:
        sim.admitSeat(seat, "")
        writer.writeJoin(0, seat, seatAlias(seat), "")
      while sim.tick < 60 and not state.finished:
        discard state.runEpisodeFrame(sim, engine, writer, 0)
      ## the fault path, written and applied exactly as advanceEpisodeFrame
      ## would on a caught exception
      sim.endReason = ReasonFault
      sim.stopDetail = "forced fault"
      writer.writeStop(state.frame, EndRuleFault)
      sim.applyStop(EndRuleFault)
      state.finished = true
      state.finishEpisode(sim, writer)
      check sim.endRule == EndRuleFault
      var back = rederive(writer.bytes())
      back.playOut()
      check back.player.hashMismatchTick == -1
      check back.sim.endRule == EndRuleFault
      ## `endReason` is a chat-record fact (the result record), re-applied into
      ## non-hashed fields at playback -- the STOP record is what re-derives
      ## the endRule.
      for record in parseReplayBytes(writer.bytes()).chats:
        back.sim.applyReplayChat(record.text)
      check back.sim.endReason == ReasonFault

  test "replay is self-sufficient":
    ## 25. The bytes alone yield seat names, aliases, policy kinds, the full
    ##     config, the seed, every order record, every chat record and the
    ##     result.
    var config = testConfig(maxTicks = 120)
    var engine = scriptedEngine(config)
    engine.seats[1].isLlm = true
    engine.seats[1].prompt = "a strategy"
    engine.seats[1].label = "rware-warehouse-picker"
    var sim = initSimServer(config)
    var writer = openReplayWriter("", config.configJson())
    var state = initEpisodeState()
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "the-real-name-" & $seat)
      writer.writeJoin(0, seat, "the-real-name-" & $seat, "tok" & $seat)
      sim.seatPolicyKind[seat] = engine.policyKind(seat)
      writer.writeChat(0, seat, registerRecord(
        seat, engine.seats[seat].label, engine.policyKind(seat),
        $engine.seats[seat].baseline))
    while not state.finished:
      discard state.runEpisodeFrame(sim, engine, writer, 0)
    state.finishEpisode(sim, writer)

    let data = parseReplayBytes(writer.bytes())
    check data.gameName == GameName
    check data.gameVersion == GameVersion
    check data.orders.len == SeatCount * sim.turnsPlayed
    check data.hashes.len > 0
    check data.configField("seed") == $config.seed
    check data.configField("protocol") == ProtocolId
    check data.configField("num_agents") == $SeatCount
    var back = initSimServer(configFromReplay(data))
    back.applyJoinRecords(data)
    for record in data.chats:
      back.applyReplayChat(record.text)
    for seat in 0 ..< SeatCount:
      check back.seatNames[seat] == "the-real-name-" & $seat
      check back.joined[seat]
    check back.seatPolicyKind[1] == "llm"
    check back.seatPolicyLabel[1] == "rware-warehouse-picker"
    check back.endReason == sim.endReason
    ## the prompt is NEVER in the bytes
    check "a strategy" notin writer.bytes()

  test "replay_summary is strict UTF-8 JSON":
    ## 26. Run tools/replay_summary.py over a replay whose every capped field is
    ##     filled to exactly its cap with 4-byte emoji; the output must parse
    ##     under a STRICT UTF-8 JSON parser and report the protocol.
    let dir = getTempDir() / "rware-summary-test"
    createDir(dir)
    defer: removeDir(dir)
    let path = dir / "capped.replay"

    var config = testConfig(maxTicks = 60)
    var sim = initSimServer(config)
    var writer = openReplayWriter(path, config.configJson())
    var state = initEpisodeState()
    var engine = scriptedEngine(config)
    var saySrc, noteSrc = ""
    for _ in 0 ..< 400:
      saySrc.add("\u{1F6E1}")
      noteSrc.add("\u{1F525}")
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "\u{1F680}driver" & $seat)
      writer.writeJoin(0, seat, "\u{1F680}driver" & $seat, "")
    while not state.finished:
      ## every recorded free-text field filled to exactly its cap
      for seat in 0 ..< SeatCount:
        sim.directives[seat].say = sanitizeSay(saySrc)
        sim.directives[seat].notes = sanitizeLine(noteSrc, MaxNoteRunes)
      discard state.runEpisodeFrame(sim, engine, writer, 0)
    sim.stopDetail = sanitizeLine(noteSrc, MaxStopDetailRunes)
    state.finishEpisode(sim, writer)
    check fileExists(path)

    let script = repoRoot() / "tools" / "replay_summary.py"
    let (output, code) = execCmdEx("python3 " & quoteShell(script) & " " &
      quoteShell(path))
    check code == 0
    check output.validateUtf8() == -1
    let summary = parseJson(output)
    check summary["protocol"].getStr() == ProtocolId
    check summary["game"].getStr() == GameName
    check summary["tickCount"].getInt() > 0
    check summary["orders"].len > 0
    check summary["results"]["reason"].getStr() in
      [ReasonComplete, ReasonDeadline]
    for line in summary["radio"]:
      check line["text"].getStr().runeLen <= MaxSayRunes
      check line["text"].getStr().validateUtf8() == -1

  test "every recorded string is rune-truncated":
    ## Byte truncation is what makes a replay that renders in a browser fail a
    ## strict UTF-8 parser, so the whole file is validated as UTF-8 and every
    ## capped field is checked in runes.
    var config = testConfig(maxTicks = 40)
    var sim = initSimServer(config)
    var writer = openReplayWriter("", config.configJson())
    var state = initEpisodeState()
    var engine = scriptedEngine(config)
    var emoji = ""
    for _ in 0 ..< 500:
      emoji.add("\u{1F6E1}")
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "")
    while not state.finished:
      for seat in 0 ..< SeatCount:
        sim.directives[seat].say = sanitizeSay(emoji)
      discard state.runEpisodeFrame(sim, engine, writer, 0)
    state.finishEpisode(sim, writer)
    for record in parseReplayBytes(writer.bytes()).chats:
      check record.text.validateUtf8() == -1
      if record.text.startsWith("{"):
        let node = parseJson(record.text)
        if node.kind == JObject and not node{"say"}.isNil:
          check node{"say"}.getStr().runeLen <= MaxSayRunes

  test "a corrupted hash is caught at the tick it happens":
    let (_, bytes) = recordEpisode(maxTicks = 60)
    var data = parseReplayBytes(bytes)
    check data.hashes.len > 10
    data.hashes[7].value = data.hashes[7].value xor 1'u64
    var runtime = initReplayRuntime(data, mismatchQuit = false)
    var sim = runtime.sim
    while runtime.player.frame <= runtime.player.maxFrame and
        runtime.player.hashMismatchTick < 0:
      runtime.player.advanceReplayFrame(sim)
    check runtime.player.hashMismatchTick == data.hashes[7].tick

  test "the pre-scan fills the sparkline and the beats before frame 1":
    let (_, bytes) = recordEpisode()
    let back = rederive(bytes)
    check back.player.scanned
    check back.player.deliverySeries.len > 0
    check back.player.beats.len > 0
    var kinds: seq[string]
    for beat in back.player.beats:
      if beat.kind notin kinds:
        kinds.add(beat.kind)
      check beat.label.len > 0
      check beat.tick >= 0
      check beat.tick <= back.player.maxFrame + 1
    ## only the four kinds the appended game block styles
    for kind in kinds:
      check kind in ["delivery", "jam", "fallback", "end"]
    let lead = back.player.leadJson()
    check lead["teams"].len == 2
    check lead["pts"].len > 0

  test "seeking re-derives the same state":
    let (_, bytes) = recordEpisode(maxTicks = 120)
    var runtime = rederive(bytes)
    var sim = runtime.sim
    runtime.player.seekTo(sim, 80)
    let a = sim.gameHash()
    runtime.player.seekTo(sim, 0)
    runtime.player.seekTo(sim, 80)
    check sim.gameHash() == a

  test "every committed fixture carries the current GameVersion":
    ## The starter's sweep, kept: a fixture recorded under an older
    ## GameVersion re-derives into a different game and the mismatch is
    ## reported as a viewer bug rather than as a stale fixture.
    var seen = 0
    for path in walkFiles(repoRoot() / "tests" / "replays" / "*.replay"):
      inc seen
      let data = parseReplayBytes(readFile(path))
      check data.gameName == GameName
      check data.gameVersion == GameVersion
      var runtime = initReplayRuntime(data, mismatchQuit = true)
      check runtime.player.hashMismatchTick == -1
    check seen > 0
