## Sim state: the server object every module reads, the `gameHash` chain the
## replay integrity check runs on, the event sink, and the lobby / game-over
## lifecycle.

import std/strutils
import sim_types, warehouse, robots, directives, events, jam

type
  DeliveryMark* = object
    tick*: int
    slot*: int
    shelf*: int
    station*: int

  SimServer* = object
    config*: GameConfig
    world*: World
    tick*: int
    episodeTick*: int
    phase*: Phase
    lobbyTicks*: int
    gameOverHold*: int
    turnIndex*: int           ## 1-based command turn
    turnsPlayed*: int
    endReason*: string
    endRule*: string
    stopDetail*: string
    banked*: bool

    directives*: array[SeatCount, RobotDirective]
    haveDirective*: array[SeatCount, bool]
    radio*: seq[tuple[slot: int, text: string]]
      ## the previous turn's `say` lines, most recent first

    jamState*: JamState
    refillDraws*: int         ## how many request refills have been made

    seatNames*: array[SeatCount, string]
    seatPolicyKind*: array[SeatCount, string]
    seatPolicyLabel*: array[SeatCount, string]
    llmTurns*: array[SeatCount, int]
    fallbackTurns*: array[SeatCount, int]
    ordersRejected*: array[SeatCount, int]
    deadSeats*: array[SeatCount, bool]
    joined*: array[SeatCount, bool]

    collectEvents*: bool
    events*: seq[SimEvent]
    lastLoads*: seq[DeliveryMark]
    lastDeliveries*: seq[DeliveryMark]
    lastStows*: seq[DeliveryMark]
    jamStarted*: bool
    jamCleared*: bool
    jamClearedTicks*: int

proc seats*(sim: SimServer): int {.inline.} =
  max(1, min(SeatCount, sim.config.numAgents))

proc turnsPerEpisode*(sim: SimServer): int {.inline.} =
  max(1, sim.config.maxTicks div max(1, sim.config.turnTicks))

proc deliveredBy*(sim: SimServer, seat: int): int {.inline.} =
  if seat < sim.world.robots.len: sim.world.robots[seat].delivered else: 0

proc stowedBy*(sim: SimServer, seat: int): int {.inline.} =
  if seat < sim.world.robots.len: sim.world.robots[seat].stowed else: 0

proc blockedBy*(sim: SimServer, seat: int): int {.inline.} =
  if seat < sim.world.robots.len: sim.world.robots[seat].blockedMoves else: 0

proc teamDelivered*(sim: SimServer): int {.inline.} =
  sim.world.teamDelivered

proc scoreOf*(sim: SimServer, seat: int): int =
  ## `100 * teamDelivered + delivered[seat]`. Higher is better, never negative:
  ## the fleet's throughput is the whole game and a seat's own count is an
  ## epsilon tie-break (a full round trip is >= 12 ticks, so
  ## `delivered[s] <= 500/12 = 41 < 100` and the ordering stays lexicographic).
  100 * sim.world.teamDelivered + sim.deliveredBy(seat)

proc fleetWon*(sim: SimServer): bool {.inline.} =
  sim.world.teamDelivered >= sim.config.parDeliveries

proc mixHash*(value: var uint64, item: int) {.inline.} =
  ## FNV-1a over the 64-bit two's-complement image of `item`. Integer only, so
  ## the native build and the wasm32 build mix identically.
  var bits = cast[uint64](int64(item))
  for _ in 0 ..< 8:
    value = value xor (bits and 0xff'u64)
    value = value * 0x100000001b3'u64
    bits = bits shr 8

proc emitEvent*(
  sim: var SimServer, kind: SimEventKind, source = -1, target = -1,
  amount = 0, detail = ""
) =
  if not sim.collectEvents:
    return
  sim.events.add(SimEvent(
    kind: kind, tick: sim.tick, source: source, target: target,
    amount: amount, detail: detail))

proc resetToLobby*(sim: var SimServer) =
  sim.world = initWorld(
    sim.config.shelfColumns, sim.config.shelfRows, sim.config.columnHeight,
    sim.seats(), sim.config.requestQueue, sim.config.sensorRange,
    sim.config.seed)
  sim.tick = 0
  sim.turnIndex = 0
  sim.phase = Lobby
  sim.lobbyTicks = 0
  sim.gameOverHold = 0
  sim.endRule = ""
  sim.banked = false
  sim.jamState = JamState()
  sim.refillDraws = 0
  sim.radio = @[]
  sim.lastLoads = @[]
  sim.lastDeliveries = @[]
  sim.lastStows = @[]
  sim.jamStarted = false
  sim.jamCleared = false
  for seat in 0 ..< SeatCount:
    sim.directives[seat] = defaultDirective()
    sim.haveDirective[seat] = false

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.endReason = ReasonComplete
  for seat in 0 ..< SeatCount:
    result.seatNames[seat] = seatAliasName(seat)
    result.seatPolicyKind[seat] = "scripted"
    result.seatPolicyLabel[seat] = "courteous"
  result.resetToLobby()

proc applyGameStart*(sim: var SimServer) =
  ## The single game starts. Applied by the SAME proc on record and on
  ## playback.
  sim.phase = Playing
  sim.tick = 0
  sim.turnIndex = 0

proc startGame*(sim: var SimServer) =
  sim.applyGameStart()

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  sim.phase == Lobby and sim.lobbyTicks >= sim.config.lobbyJoinTimeoutTicks

proc gameHash*(sim: SimServer): uint64 =
  ## The per-tick integrity chain. Mix order is FIXED: per robot, per shelf,
  ## the request queue in order, the fleet counters, the active jam set, the
  ## clock. One divergent bit between the native writer and the wasm
  ## re-simulation is caught at the tick it happens.
  result = 0xcbf29ce484222325'u64
  for slot in 0 ..< sim.world.robots.len:
    let robot = sim.world.robots[slot]
    result.mixHash(slot)
    result.mixHash(sim.world.wh.cellX(robot.cell))
    result.mixHash(sim.world.wh.cellY(robot.cell))
    result.mixHash(robot.facing)
    result.mixHash(robot.carrying)
    result.mixHash(robot.stuck)
  for id in 0 ..< sim.world.shelves.len:
    let shelf = sim.world.shelves[id]
    result.mixHash(id)
    result.mixHash(sim.world.wh.cellX(shelf.cell))
    result.mixHash(sim.world.wh.cellY(shelf.cell))
    result.mixHash(shelf.carrier)
  for id in sim.world.requestQueue:
    result.mixHash(id)
  result.mixHash(sim.world.teamDelivered)
  for slot in 0 ..< sim.world.robots.len:
    result.mixHash(sim.world.robots[slot].delivered)
    result.mixHash(sim.world.robots[slot].stowed)
  for slot in sim.jamState.members:
    result.mixHash(slot)
  result.mixHash(sim.tick)

proc bankGame*(sim: var SimServer, endRule: string) =
  ## Ends the episode's single game. Called by the SAME proc on record and on
  ## playback, so a wall-clock stop re-derives identically.
  if sim.banked:
    return
  sim.banked = true
  sim.endRule = endRule
  sim.phase = GameOver
  sim.gameOverHold = 0
  sim.emitEvent(PhaseChange, detail = endRule)

proc parseHashHex*(text: string): uint64 =
  parseBiggestUInt("0x" & text).uint64

proc gameHashHex*(sim: SimServer): string =
  toHex(sim.gameHash())
