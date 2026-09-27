## JSONL training bridge over the game's four-seat episode driver.

import std/[hashes, json]
import sim, decide, episode, replays, roster, baselines, policy_actions

var
  world: SimServer
  engine: DecisionEngine
  driver: EpisodeState
  writer: ReplayWriter
  decisionId: int
  pendingSeat: int
  pendingOrders: array[SeatCount, string]

proc dispatchBridge(turn, deadlineMs: int,
                    requests: seq[ExternalRequest]) =
  discard turn
  discard deadlineMs
  discard requests

proc collectBridge(turn, deadlineMs: int,
                   requests: seq[ExternalRequest]): seq[string] =
  discard turn
  discard deadlineMs
  for request in requests: result.add(pendingOrders[request.seat])

proc currentView(): JsonNode =
  engine.seatView(world, pendingSeat, includeNotes = true)

proc currentDecision(): JsonNode =
  let view = currentView()
  var legalActions = newJArray()
  for action in actionChoices(view):
    if action.kind != JNull: legalActions.add(action)
  %*{"kind": "decision", "game": "rware-warehouse",
    "decision_id": decisionId, "seat": pendingSeat,
    "engine_seat": pendingSeat, "turn": world.turnIndex,
    "semantic_view": view, "inbox": [],
    "messages": [{"role": "user", "content": $view}],
    "speech_messages": [],
    "action_schema": {"type": "object", "enum": legalActions},
    "typed_question": newJNull()}

proc reset(request: JsonNode): JsonNode =
  doAssert request["players"].getInt() == SeatCount
  var config = defaultGameConfig()
  config.seed = int(hash(request["seed"].getStr()) and hash(high(int)))
  config.turnSpacingMs = 0
  world = initSimServer(config)
  engine = initDecisionEngine(config, enableLlm = false)
  engine.externalDispatch = dispatchBridge
  engine.externalCollect = collectBridge
  driver = initEpisodeState()
  writer = openReplayWriter("", config.configJson())
  for seat in 0 ..< SeatCount:
    world.admitSeat(seat, seatAlias(seat))
    writer.writeJoin(0, seat, seatAlias(seat), "")
    engine.seats[seat].isExternal = true
    world.seatPolicyKind[seat] = engine.policyKind(seat)
    pendingOrders[seat] = ""
  doAssert driver.maybeStartGame(world, writer)
  world.turnIndex = 1
  world.refreshSeatMemory()
  engine.preparedTurn = true
  decisionId = 0
  pendingSeat = 0
  currentDecision()

proc step(request: JsonNode): JsonNode =
  if request["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(request["response"].getStr())
  if action notin actionChoices(currentView()):
    return %*{"kind": "rejected", "reason": "action outside visible order catalog"}
  pendingOrders[pendingSeat] = $action
  inc decisionId
  if pendingSeat + 1 < SeatCount:
    inc pendingSeat
    return %*{"kind": "accepted", "action": action,
      "observation": currentDecision()}
  discard driver.runEpisodeFrame(world, engine, writer, 0)
  while not driver.finished and not
      (world.phase == Playing and world.tick mod world.config.turnTicks == 0 and
        world.tick div world.config.turnTicks + 1 != driver.lastTurnKey):
    discard driver.runEpisodeFrame(world, engine, writer, 0)
  pendingSeat = 0
  if driver.finished:
    driver.finishEpisode(world, writer)
    var scores = newJObject()
    var utilities = newJObject()
    let utility = 2.0 * min(1.0,
      world.teamDelivered().float / world.config.parDeliveries.float) - 1.0
    for seat in 0 ..< SeatCount:
      scores[$seat] = %world.scoreOf(seat)
      utilities[$seat] = %utility
    return %*{"kind": "accepted", "action": action,
      "observation": {"kind": "terminal", "scores": scores,
        "utilities": utilities}}
  world.turnIndex = world.tick div world.config.turnTicks + 1
  world.refreshSeatMemory()
  engine.preparedTurn = true
  %*{"kind": "accepted", "action": action,
    "observation": currentDecision()}

proc teacher(): JsonNode =
  let directive = scriptedDirective(world, pendingSeat,
    blShuttle, engine.baselineParams)
  let choices = actionChoices(currentView())
  var selected = choices[0]
  case directive.order.kind
  of okHold: selected = choices[0]
  of okYield: selected = choices[1]
  of okDeliver: selected = choices[2 + directive.order.station]
  of okFetch:
    for index in 4 ..< 8:
      if choices[index].kind != JNull and
          choices[index]["shelf"].getStr() ==
            shelfLabel(directive.order.shelf):
        selected = choices[index]
  of okStow:
    for index in 8 ..< policy_actions.ActionCount:
      if choices[index].kind != JNull and
          choices[index]["x"].getInt() == directive.order.x and
          choices[index]["y"].getInt() == directive.order.y:
        selected = choices[index]
  %*{"response": $selected}

when isMainModule:
  for line in stdin.lines:
    let request = parseJson(line)
    let response = case request["kind"].getStr()
      of "reset": reset(request)
      of "encode": %*{"decision_id": decisionId,
        "values": values(currentView()),
        "actions": actionChoices(currentView())}
      of "teacher": teacher()
      of "step": step(request)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
