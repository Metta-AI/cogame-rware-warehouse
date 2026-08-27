## The end-to-end episode: the SHARED driver, artifacts, and the two ways an
## episode can be stalled from outside.
##
## `runHeadlessEpisode` calls the exact per-frame proc `server.nim` calls, so
## the test and production can never run two different loops.

import std/[json, os, sets, strutils, unittest]
import helpers

proc resultKeys(text: string): HashSet[string] =
  for key, _ in parseJson(text).pairs:
    result.incl(key)

suite "rware engine":

  test "episode writes artifacts":
    ## 21. A real four-seat episode against a temp-dir COGAME_* URI set:
    ##     results.json and the .replay are written, reason == complete,
    ##     teamDelivered > 0, scores agree with the formula, and the results
    ##     key set equals the manifest's results_schema key set EXACTLY.
    let dir = getTempDir() / "rware-engine-test"
    createDir(dir)
    defer: removeDir(dir)
    let replayPath = dir / "episode.replay"
    var config = testConfig(maxTicks = 200)
    let run = runScriptedEpisode(config, replayPath)
    check fileExists(replayPath)
    check getFileSize(replayPath) > 0
    check run.sim.endReason == ReasonComplete
    check run.sim.endRule == EndRuleTickCap
    check run.sim.teamDelivered() > 0
    let text = run.sim.fleetResultsJson()
    writeFile(dir / "results.json", text)
    check fileExists(dir / "results.json")
    let results = parseJson(text)
    check results["names"].len == SeatCount
    check results["scores"].len == SeatCount
    for seat in 0 ..< SeatCount:
      check results["scores"][seat].getInt() ==
        100 * run.sim.teamDelivered() + run.sim.deliveredBy(seat)
      check results["scores"][seat].getInt() >= 0
    check results["winner"].kind == JNull
    ## the closed schema: exactly the manifest's keys, no more and no fewer
    let declared = manifestJson()["game"]["results_schema"]["properties"]
    var want: HashSet[string]
    for key, _ in declared.pairs:
      want.incl(key)
    let got = resultKeys(text)
    checkpoint("only in results: " & $(got - want))
    checkpoint("only in the manifest: " & $(want - got))
    check got == want

  test "no seat can stall the episode":
    ## 22. A seat that never connects at all produces a finished episode inside
    ##     the wall-clock budget, with deadSeats set, fallbackTurns counted,
    ##     and exactly one closed-schema failure payload.
    var config = testConfig(maxTicks = 120)
    let run = runScriptedEpisode(
      config, "", joinSeats = {0'u8, 2'u8})
    check run.state.finished
    check run.sim.endReason == ReasonComplete
    check run.sim.deadSeats[1]
    check run.sim.deadSeats[3]
    check not run.sim.deadSeats[0]
    check run.state.failureSlot == 1
    ## the platform's CLOSED payload -- exactly two keys, nothing else
    let payload = parseJson(playerFailurePayload(1, "slot 1 never joined"))
    var keys: HashSet[string]
    for key, _ in payload.pairs:
      keys.incl(key)
    check keys == toHashSet(["message", "failed_policy_index"])
    check payload["failed_policy_index"].getInt() == 1
    ## and the replay says WHY, per turn, rather than looking like a filler
    var disconnected = 0
    for record in parseReplayBytes(run.bytes).chats:
      if "\"cause\":\"disconnected\"" in record.text:
        inc disconnected
    check disconnected > 0

  test "budget guard settles early, still complete":
    ## 23. With the guard forced, the episode finishes `complete`, not
    ##     `deadline`, and the matching record names the turn.
    var config = testConfig(maxTicks = 200)
    config.wallClockBudgetSeconds = 10
    var engine = scriptedEngine(config)
    engine.seats[0].isLlm = true
    engine.seats[0].prompt = "a prompt, so the seat is an LLM seat"
    let run = runHeadlessEpisode(config, engine, "")
    check run.sim.endReason == ReasonComplete
    check run.sim.endRule == EndRuleTickCap
    check engine.llmOff
    var guarded = 0
    for record in parseReplayBytes(run.bytes).chats:
      if "\"k\":\"budget_guard\"" in record.text:
        inc guarded
        check "\"turn\":" in record.text
    check guarded == 1
    ## an LLM seat with no credentials falls back every turn, and the count is
    ## in the results
    check run.sim.fallbackTurns[0] > 0
    check run.sim.llmTurns[0] == 0

  test "the wall-clock stop settles with the real deliveries":
    ## A deadline episode is still rankable: the stop banks the game where it
    ## stands, it never zeroes the count.
    var config = testConfig(maxTicks = 400)
    var sim = initSimServer(config)
    var writer = openReplayWriter("", config.configJson())
    var state = initEpisodeState()
    var engine = scriptedEngine(config)
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "")
    ## run 200 ticks normally, then force the clock past the budget
    while sim.tick < 200 and not state.finished:
      discard state.runEpisodeFrame(sim, engine, writer, 0)
    let before = sim.teamDelivered()
    check before > 0
    discard state.runEpisodeFrame(
      sim, engine, writer, config.wallClockBudgetSeconds + 1)
    check state.finished
    check sim.endReason == ReasonDeadline
    check sim.endRule == EndRuleWallClock
    check sim.teamDelivered() == before
    check sim.scoreOf(0) >= 0

  test "the fleet radio carries every seat's last-turn say":
    var config = testConfig(maxTicks = 60)
    var sim = initSimServer(config)
    var engine = initDecisionEngine(config)
    sim.applyGameStart()
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "")
      sim.directives[seat].say = "line from " & seatAlias(seat)
    discard engine.turn(sim, 1, 0)
    ## the scripted baselines emit no say of their own, so the radio is what
    ## the previous turn left behind -- and a seat never hears itself
    for seat in 0 ..< SeatCount:
      let view = engine.seatView(sim, seat, includeNotes = false)
      for line in view["radio"]:
        check line["from"].getStr() != seatAliasName(seat)

  test "the observation hides everything a driver may not know":
    var sim = playingSim()
    var engine = initDecisionEngine(sim.config)
    sim.seatNames = ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"]
    sim.seatPolicyKind = ["llm", "llm", "scripted", "scripted"]
    engine.notes[1] = "bravo's private notes"
    for seat in 0 ..< SeatCount:
      let text = $engine.seatView(sim, seat, includeNotes = true)
      var secrets = @["daveey", "Baseline (1)", "Baseline (2)", "policyKind"]
      if seat != 1:
        ## seat 1 legitimately sees its OWN notes echoed back
        secrets.add("bravo's private notes")
      for secret in secrets:
        if secret in text:
          checkpoint("seat " & $seat & " can see \"" & secret & "\"")
          fail()
      ## and it CAN see its own alias, the request board and the floor plan
      check seatAliasName(seat) in text
      check "\"requests\"" in text
      check "\"warehouse\"" in text
      check "\"sensor_range\"" in text

  test "the driver is handed the floor plan":
    ## The note's first visible fact: the whole floor plan, `#` storage slot,
    ## `.` aisle, `W` workstation -- the vocabulary the system prompt uses. It
    ## is sent with every request because a provider call carries no
    ## conversation state, and it is the SAME plan every turn.
    var sim = playingSim()
    var engine = initDecisionEngine(sim.config)
    engine.seats[0].prompt = "operator guidance"
    let
      view = $engine.seatView(sim, 0, includeNotes = false)
      message = engine.seatUserMessage(sim, 0, view, retry = false)
      plan = sim.world.wh.asciiMap()
    check plan.len > 0
    check plan in message
    check "operator guidance" in message
    check view in message
    ## every row of the plan is a row of the board, in the shipped vocabulary
    let rows = plan.splitLines()
    check rows.len == sim.world.wh.height
    for row in rows:
      check row.len == sim.world.wh.width
      for ch in row:
        check ch in {'#', '.', 'W'}
    ## and it does not change between turns or between seats
    check engine.seatUserMessage(sim, 1, view, retry = true).contains(plan)

  test "results record cross-play honestly":
    var config = testConfig(maxTicks = 60)
    var engine = scriptedEngine(config)
    engine.seats[0].isLlm = true
    engine.seats[0].prompt = "a prompt"
    let mixed = runHeadlessEpisode(config, engine, "")
    check mixed.sim.crossPlay()
    check parseJson(mixed.sim.fleetResultsJson())["crossPlay"].getBool()
    let allScripted = runScriptedEpisode(config)
    check not allScripted.sim.crossPlay()
