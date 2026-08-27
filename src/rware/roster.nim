## Join, auth, the two name spaces, and the results document.
##
## TWO NAME SPACES, and both are required. In-game the seats are `Alpha`,
## `Bravo`, `Charlie` and `Delta`; those aliases are the only names that appear
## in an observation, a prompt, an order, a `say`, a radio line or a sprite
## label, so a driver can never learn who it is working with. The seats' REAL
## policy names live only in `results.names`, in the replay's join records and
## in the viewer's scorebug -- spectator side only, with `showPlayerLabels`
## false.

import std/[json, strutils]
import sim_types, sim_state, sim_config, directives, replays

export IdentityNames

proc seatAlias*(slot: int): string =
  IdentityNames[slot mod IdentityNames.len]

proc cleanPlayerName*(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch in {' ', '\t', '\n', '\r'}:
      ch = '_'

proc joinError*(sim: SimServer, slot: int, token: string): string =
  ## The rejection reason for bad roster credentials, or "" to admit.
  if slot < 0 or slot >= sim.config.numAgents:
    return "Player slot must be between 0 and " &
      $(sim.config.numAgents - 1) & "."
  if not sim.config.playerJoinAllowed(slot, token):
    return "Player token does not match configured slot " & $slot & "."
  ""

proc admitSeat*(sim: var SimServer, slot: int, name: string) =
  if slot < 0 or slot >= SeatCount:
    return
  sim.joined[slot] = true
  if name.len > 0:
    sim.seatNames[slot] = name
  elif sim.config.configuredPlayerName(slot).len > 0:
    sim.seatNames[slot] = sim.config.configuredPlayerName(slot)

proc seatsJoined*(sim: SimServer): int =
  for slot in 0 ..< sim.config.numAgents:
    if sim.joined[slot]:
      inc result

proc crossPlay*(sim: SimServer): bool =
  ## True when at least one LLM seat and at least one scripted seat sat
  ## together -- the idea's integrity note, recorded as a fact about the
  ## episode rather than asserted.
  var llm, scripted = false
  for seat in 0 ..< SeatCount:
    if sim.seatPolicyKind[seat] == "llm": llm = true
    else: scripted = true
  llm and scripted

proc fleetResultsJson*(sim: SimServer): string =
  ## The CLOSED results schema. Adding a key means updating this proc, the
  ## manifest's `results_schema` and tools/ci/docker_smoke.sh's expected-key
  ## set in the same commit -- Coworld schemas are closed and undeclared keys
  ## are dropped.
  var
    names = newJArray()
    aliases = newJArray()
    scores = newJArray()
    win = newJArray()
    delivered = newJArray()
    stowed = newJArray()
    blockedMoves = newJArray()
    policyKinds = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
    ordersRejected = newJArray()
    deadSeats = newJArray()
  let won = sim.fleetWon()
  for seat in 0 ..< SeatCount:
    names.add(%sim.seatNames[seat])
    aliases.add(%seatAlias(seat))
    scores.add(%sim.scoreOf(seat))
    ## The same boolean for all four seats: "did the fleet do its job", not a
    ## duel. A cooperative episode has no winner, so `winner` is always null.
    win.add(%won)
    delivered.add(%sim.deliveredBy(seat))
    stowed.add(%sim.stowedBy(seat))
    blockedMoves.add(%sim.blockedBy(seat))
    policyKinds.add(%sim.seatPolicyKind[seat])
    llmTurns.add(%sim.llmTurns[seat])
    fallbackTurns.add(%sim.fallbackTurns[seat])
    ordersRejected.add(%sim.ordersRejected[seat])
    deadSeats.add(%sim.deadSeats[seat])
  $(%*{
    "names": names,
    "aliases": aliases,
    "scores": scores,
    "win": win,
    "winner": newJNull(),
    "reason": sim.endReason,
    "teamDelivered": sim.teamDelivered(),
    "parDeliveries": sim.config.parDeliveries,
    "delivered": delivered,
    "stowed": stowed,
    "blockedMoves": blockedMoves,
    "jams": sim.jamState.count,
    "jamTicks": sim.jamState.ticksTotal,
    "longestJamTicks": sim.jamState.longestTicks,
    "finalTick": sim.tick,
    "turnsPlayed": sim.turnsPlayed,
    "seed": sim.config.seed,
    "policyKinds": policyKinds,
    "crossPlay": sim.crossPlay(),
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "ordersRejected": ordersRejected,
    "deadSeats": deadSeats,
    "stopDetail": sim.stopDetail.sanitizeLine(MaxStopDetailRunes)
  })

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record: the whole results document, written once into
  ## the replay chat stream at episode end. It is what makes the replay
  ## self-sufficient -- without it the outcome exists only at
  ## COGAME_RESULTS_URI, which a spectator holding the bytes cannot read.
  "{\"k\":\"result\",\"results\":" & sim.fleetResultsJson() & "}"

proc playerFailurePayload*(slot: int, message: string): string =
  ## The platform's CLOSED player-failure payload: exactly `message` and
  ## `failed_policy_index`, nothing else.
  $(%*{"message": message, "failed_policy_index": slot})

proc applyJoinRecords*(sim: var SimServer, data: ReplayData) =
  ## Playback: the real seat names come back out of the join records, which is
  ## what lets the scorebug show them spectator-side.
  for record in data.joins:
    if record.slot >= 0 and record.slot < SeatCount:
      sim.seatNames[record.slot] = record.name
      sim.joined[record.slot] = true

proc applyReplayChat*(sim: var SimServer, text: string) =
  ## Playback: chat records are re-applied into NON-HASHED fields only. A
  ## `register` record restores the policy kind and label; a `directive`
  ## record bumps that seat's `llmTurns` or `fallbackTurns` by its source, the
  ## same way the live loop counts them. None of this can affect the
  ## simulation.
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject:
    return
  let kind = node{"k"}.getStr()
  let slot = node{"slot"}.getInt(-1)
  case kind
  of "register":
    if slot >= 0 and slot < SeatCount:
      sim.seatPolicyKind[slot] = node{"kind"}.getStr("scripted")
      sim.seatPolicyLabel[slot] = node{"policy"}.getStr()
      if sim.seatPolicyLabel[slot].len > 0 and
          sim.seatNames[slot] == seatAlias(slot):
        sim.seatNames[slot] = sim.seatPolicyLabel[slot]
  of "directive":
    ## Both per-turn counters come from the DIRECTIVE record, which is written
    ## once per seat per turn carrying the source of the directive that was
    ## actually installed -- the same rule the live loop counts by
    ## (episode.nim). Counting `fallback` records instead double-counted a seat
    ## that failed both attempts (two attempt-2 records) and missed a seat that
    ## never got to call at all (one attempt-1 record, cause `budget_guard`,
    ## `rate_guard` or `no_credentials`), so the re-derived numbers disagreed
    ## with the recorded ones in both directions.
    if slot >= 0 and slot < SeatCount:
      case node{"source"}.getStr()
      of "llm": inc sim.llmTurns[slot]
      of "fallback": inc sim.fallbackTurns[slot]
      else: discard
  of "result":
    let results = node{"results"}
    if not results.isNil and results.kind == JObject:
      sim.endReason = results{"reason"}.getStr(sim.endReason)
  else:
    discard
