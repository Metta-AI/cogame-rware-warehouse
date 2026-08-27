## The decision layer: the per-turn loop that asks all four drivers what their
## robot does next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (20 ticks), 25 turns per episode. At
## each turn the server builds ALL FOUR seats' request bodies and issues them
## as ONE parallel batch -- this is a simultaneous-decision game, so querying
## seats one after another would quadruple the wall clock for nothing.
##
## DEGRADE, NEVER HANG. Every wait is bounded: attempt 1 gets `attempt1Ms`, the
## single retry gets `retryMs`, the whole turn sits inside a monotonic
## `turnBudgetMs` deadline, and a rolling 60 s request counter keeps the
## episode under the sidecar's 30 req/min cap. On a second failure that seat
## plays the `courteous` scripted order for that turn and a `fallback` record
## names the cause. No failure mode leaves a robot unactuated: the pilot always
## has an order -- this turn's, else last turn's, else `courteous`'s.

import std/[json, monotimes, os, strutils, times]
import curly
import sim, baselines, llm

const
  RateWindowSeconds = 60
  RateWindowLimit = 28
    ## The sidecar caps 30 requests/minute PER EPISODE. `turnSpacingMs` pins
    ## the steady state at 4 seats x 60/12 = 20 req/min, but a turn in which
    ## every seat retries issues 8. The rolling counter is the guard: a seat
    ## that would push the trailing-60 s count over this takes the `courteous`
    ## order with `cause = "rate_guard"` -- bounded, logged, never a sleep on
    ## the episode's critical path.

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field --
    ## or never registers at all -- is `courteous`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: array[SeatCount, SeatPolicy]
    notes*: array[SeatCount, string]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    lastView*: array[SeatCount, JsonNode]
    requestTimes*: seq[MonoTime]
    baselineParams*: BaselineParams
      ## The swept tunables (tools/tune_baselines.nim). Held on the engine so
      ## the sweep can drive a whole episode with one candidate set without
      ## touching the shipped defaults.

proc initDecisionEngine*(config: GameConfig): DecisionEngine =
  result.client = newLlmClient(config)
  result.baselineParams = DefaultBaselineParams
  for seat in 0 ..< SeatCount:
    result.seats[seat].baseline = DefaultBaseline
    result.seats[seat].label = $DefaultBaseline
    result.lastView[seat] = newJNull()

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < SeatCount and engine.seats[seat].isLlm: "llm"
  else: "scripted"

# ---------------------------------------------------------------------------
#  The per-seat view
# ---------------------------------------------------------------------------

proc seatView*(
  engine: DecisionEngine, sim: SimServer, seat: int, includeNotes: bool
): JsonNode =
  ## Everything this seat may legitimately know. The floor plan and the request
  ## board are public and static warehouse knowledge; every DYNAMIC fact --
  ## other robots, which storage slots are free, who is carrying what -- is
  ## limited to Chebyshev `sensorRange` of the seat's OWN robot. The other
  ## seats' orders, notes, real names, policy kinds and fallback statistics are
  ## never in here, and no real policy name ever is: the seats are Alpha,
  ## Bravo, Charlie and Delta.
  let
    wh = sim.world.wh
    robot = sim.world.robots[seat]
  var fleet = newJArray()
  for other in 0 ..< sim.seats():
    fleet.add(%seatAliasName(other))
  var requests = newJArray()
  for id in sim.world.requestQueue:
    if id < 0 or id >= sim.world.shelves.len:
      continue
    requests.add(%*{
      "shelf": shelfLabel(id),
      "home": [wh.cellX(sim.world.shelves[id].home),
               wh.cellY(sim.world.shelves[id].home)]})
  var seenRobots = newJArray()
  for other in 0 ..< sim.world.robots.len:
    if other == seat:
      continue
    if not sim.world.visibleTo(seat, sim.world.robots[other].cell):
      continue
    seenRobots.add(%*{
      "alias": seatAliasName(other),
      "cell": [wh.cellX(sim.world.robots[other].cell),
               wh.cellY(sim.world.robots[other].cell)],
      "facing": facingName(sim.world.robots[other].facing),
      "loaded": sim.world.robots[other].carrying >= 0})
  var freeSlots = newJArray()
  for cell in freeSlotsNear(sim.world, seat, MaxFreeSlotsReported):
    freeSlots.add(%[wh.cellX(cell), wh.cellY(cell)])
  var shelvesHere = newJArray()
  for id in 0 ..< sim.world.shelves.len:
    let shelf = sim.world.shelves[id]
    if shelf.carrier >= 0 or not sim.world.visibleTo(seat, shelf.cell):
      continue
    shelvesHere.add(%*{
      "shelf": shelfLabel(id),
      "cell": [wh.cellX(shelf.cell), wh.cellY(shelf.cell)],
      "requested": sim.world.requested[id]})
  var radio = newJArray()
  for line in sim.radio:
    if radio.len >= MaxRadioLines:
      break
    if line.slot == seat:
      continue
    radio.add(%*{
      "from": seatAliasName(line.slot),
      "text": line.text.truncateRunes(MaxSayRunes)})
  var jamRobots = newJArray()
  for slot in sim.jamState.members:
    jamRobots.add(%seatAliasName(slot))
  result = %*{
    "you": seatAliasName(seat),
    "fleet": fleet,
    "turn": sim.turnIndex,
    "of": sim.turnsPerEpisode(),
    "tick": sim.tick,
    "turn_ticks": sim.config.turnTicks,
    "ticks_left": max(0, sim.config.maxTicks - sim.tick),
    "warehouse": {
      "width": wh.width,
      "height": wh.height,
      "stations": {
        "W1": [wh.cellX(wh.goals[0]), wh.cellY(wh.goals[0])],
        "W2": [wh.cellX(wh.goals[1]), wh.cellY(wh.goals[1])]
      },
      "storage_slots": wh.shelfCount(),
      "sensor_range": sim.world.sensorRange
    },
    "requests": requests,
    "you_are": {
      "cell": [wh.cellX(robot.cell), wh.cellY(robot.cell)],
      "facing": facingName(robot.facing),
      "loaded": robot.carrying >= 0,
      "carrying": (if robot.carrying >= 0: %shelfLabel(robot.carrying)
                   else: newJNull()),
      "order": $sim.directives[seat].order.kind & " " &
        orderArg(sim.directives[seat].order, wh),
      "order_age_turns": robot.orderAgeTurns,
      "last_order_result": $robot.lastResult,
      "blocked_ticks_last_turn": robot.blockedLastTurn,
      "on_aisle": wh.isHighway(robot.cell)
    },
    "seen": {
      "robots": seenRobots,
      "free_slots": freeSlots,
      "shelves_here": shelvesHere
    },
    "radio": radio,
    "fleet_status": {
      "delivered": sim.teamDelivered(),
      "par": sim.config.parDeliveries,
      "jam": sim.jamState.active,
      "jam_robots": jamRobots,
      "jam_ticks": (if sim.jamState.active:
                      sim.tick - sim.jamState.startedTick + 1 else: 0)
    }
  }
  if includeNotes:
    result["your_notes"] = %engine.notes[seat]

proc refreshSeatMemory*(sim: var SimServer) =
  ## Per-turn bookkeeping the observation reads: what each robot spent blocked
  ## since the previous command turn. Not hashed -- it only ever reaches a
  ## prompt, a scripted baseline and a replay `view`.
  for slot in 0 ..< sim.world.robots.len:
    sim.world.robots[slot].blockedLastTurn =
      sim.world.robots[slot].blockedThisTurn
    sim.world.robots[slot].blockedThisTurn = 0

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord*(
  turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "slot": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.sanitizeLine(MaxFallbackDetailRunes)
  })

proc registerRecord*(seat: int, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat picked.
  $(%*{
    "k": "register",
    "slot": seat,
    "alias": seatAliasName(seat),
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc recentRequests(engine: var DecisionEngine): int =
  let now = getMonoTime()
  var kept: seq[MonoTime]
  for stamp in engine.requestTimes:
    if (now - stamp).inSeconds.int < RateWindowSeconds:
      kept.add(stamp)
  engine.requestTimes = kept
  kept.len

proc turn*(
  engine: var DecisionEngine,
  sim: var SimServer,
  turnIndex, elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs each seat's directive. Returns the
  ## replay chat records this turn produced. Never raises: every failure path
  ## ends in a legal order.
  let
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  sim.turnIndex = turnIndex
  sim.refreshSeatMemory()
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun -----------------------
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "rware: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  var rateBudget = max(0, RateWindowLimit - engine.recentRequests())
  for seat in 0 ..< sim.seats():
    engine.lastView[seat] = engine.seatView(sim, seat, includeNotes = false)
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled and rateBudget > 0:
      open.add(seat)
      dec rateBudget
    elif engine.seats[seat].isLlm:
      # An LLM seat that CANNOT call the LLM this turn is a fallback, not a
      # scripted policy, and the design's cause enum names every reason.
      var directive = fallbackDirective(sim, seat, engine.baselineParams)
      directive.say = ""
      sim.applyOrders(seat, directive)
      let cause =
        if engine.llmOff: "budget_guard"
        elif rateBudget <= 0 and not engine.client.disabled: "rate_guard"
        else: "no_credentials"
      result.add(fallbackRecord(turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing courteous"))
      echo "rware llm: seat ", seat, " falling back to courteous (", cause,
        ") on turn ", turnIndex
    else:
      var directive = scriptedDirective(
        sim, seat, engine.seats[seat].baseline, engine.baselineParams)
      sim.applyOrders(seat, directive)
      if not sim.joined[seat]:
        ## Nobody is home on this seat: its robot is on autopilot for the whole
        ## episode, and the replay says WHY rather than looking like a
        ## deliberate scripted filler.
        result.add(fallbackRecord(turnIndex, seat, 1, "disconnected",
          "seat never joined; its robot plays the scripted baseline"))

  # --- the rate floor -------------------------------------------------------
  # Hold the START of consecutive batches `turnSpacingMs` apart, which pins the
  # episode at 4 seats x 60/12 = 20 req/min under the sidecar's 30.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(
          turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var view = engine.seatView(sim, seat, includeNotes = true)
      var user = $view
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{'.")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
      engine.requestTimes.add(getMonoTime())
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS. sim_config rejects a sub-second
    # value, so the floor is an identity: 9000 -> 9 s inside turnBudgetMs 14 s.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        var directive = parseRobotDirective(
          extractJsonObject(text), sim.directives[seat], sim.world.wh,
          sim.world.requestQueue)
        directive.source = dsLlm
        directive.latencyMs = latency
        engine.notes[seat] = directive.notes
        sim.ordersRejected[seat] += directive.rejected
        sim.applyOrders(seat, directive)
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          cause = "throttled"
        result.add(fallbackRecord(
          turnIndex, seat, attempt + 1, cause, error.msg))
        echo "rware llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model left answered 429, so the retry batch would
      # be refused the same way.
      echo "rware llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays courteous for this turn --------------------
  for seat in open:
    var directive = fallbackDirective(sim, seat, engine.baselineParams)
    directive.say = ""
    sim.applyOrders(seat, directive)
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(turnIndex, seat, 2, cause,
      "seat fell back to the courteous order"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "rware llm: seat ", seat, " falling back to courteous (", cause,
      ") on turn ", turnIndex

  # --- the fleet radio: every seat hears every seat's last-turn `say` -------
  var nextRadio: seq[tuple[slot: int, text: string]]
  for seat in 0 ..< sim.seats():
    let say = sim.directives[seat].say
    if say.len > 0:
      nextRadio.add((slot: seat, text: say))
  sim.radio = nextRadio
