## Shared test scaffolding: a configured sim, a headless episode, and the
## repo-root path resolution the tests read source files through.
##
## Every test runs from the repo ROOT (`nim r tests/<file>.nim`), which is what
## the source-grep gates and the manifest read depend on.

import std/[json, os, strutils]
import rware/[sim, baselines, decide, episode, replays, roster]

export sim, baselines, decide, episode, replays, roster

proc repoRoot*(): string =
  ## The repo root, resolved from THIS file rather than from the cwd, so a
  ## shard binary run from anywhere still finds the sources it greps.
  currentSourcePath().parentDir().parentDir()

proc readRepoFile*(relative: string): string =
  readFile(repoRoot() / relative)

proc repoFileExists*(relative: string): bool =
  fileExists(repoRoot() / relative)

proc testConfig*(
  shelfColumns = 3, maxTicks = 200, requestQueue = 4, seed = 42
): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.shelfColumns = shelfColumns
  result.shelfRows = 1
  result.columnHeight = 8
  result.requestQueue = requestQueue
  result.maxTicks = maxTicks
  result.turnTicks = 20
  result.turnSpacingMs = 0
  result.gameOverTicks = 2
  result.lobbyJoinTimeoutTicks = 1
  result.players = @[
    PlayerConfig(name: "Alpha"), PlayerConfig(name: "Bravo"),
    PlayerConfig(name: "Charlie"), PlayerConfig(name: "Delta")]
  result.clampConfig()

proc playingSim*(shelfColumns = 3, seed = 42): SimServer =
  ## A sim with the warehouse laid out, the robots spawned and the shift
  ## started.
  result = initSimServer(testConfig(shelfColumns = shelfColumns, seed = seed))
  result.applyGameStart()
  for slot in 0 ..< result.world.robots.len:
    result.world.noteVisibleSlots(slot)

proc emptyBoard*(shelfColumns = 3): SimServer =
  ## A started shift with every robot removed and every shelf lifted off the
  ## floor, so a unit test can place exactly the pieces it wants to reason
  ## about.
  result = playingSim(shelfColumns)
  result.world.robots.setLen(0)
  for id in 0 ..< result.world.shelves.len:
    result.world.shelves[id].cell = result.world.shelves[id].home
    result.world.shelves[id].carrier = -1
  result.world.rebuildLayers()

proc clearShelves*(sim: var SimServer) =
  ## Removes every standing shelf from the occupancy layer -- the floor becomes
  ## a plain grid, which is what most movement tests want to reason about.
  for cell in 0 ..< sim.world.shelfAt.len:
    sim.world.shelfAt[cell] = -1
  for id in 0 ..< sim.world.shelves.len:
    sim.world.shelves[id].cell = -1
    sim.world.shelves[id].carrier = -1

proc cellOf*(sim: SimServer, x, y: int): int {.inline.} =
  sim.world.wh.cellIndex(x, y)

proc place*(sim: var SimServer, x, y, facing: int, carrying = -1): int =
  ## Adds one robot and returns its slot. Slots ascend in call order, which is
  ## the resolution order the whole tick is pinned to.
  result = sim.world.robots.len
  sim.world.robots.add(Robot(
    cell: sim.cellOf(x, y), facing: facing, carrying: carrying,
    lastResult: orRunning))
  sim.world.seenEmpty.add(newSeq[bool](sim.world.robotAt.len))
  if carrying >= 0:
    sim.world.shelves[carrying].carrier = result
    sim.world.shelves[carrying].cell = sim.cellOf(x, y)
  sim.world.rebuildLayers()

proc standShelf*(sim: var SimServer, id, x, y: int) =
  sim.world.shelves[id].cell = sim.cellOf(x, y)
  sim.world.shelves[id].carrier = -1
  sim.world.rebuildLayers()

proc requestOnly*(sim: var SimServer, ids: openArray[int]) =
  for id in 0 ..< sim.world.requested.len:
    sim.world.requested[id] = false
  sim.world.requestQueue = @[]
  for id in ids:
    sim.world.requestQueue.add(id)
    sim.world.requested[id] = true

proc setOrder*(
  sim: var SimServer, seat: int, kind: OrderKind,
  shelf = -1, station = 0, x = -1, y = -1, hasCell = false
) =
  sim.directives[seat].order = RobotOrder(
    kind: kind, shelf: shelf, station: station, x: x, y: y, hasCell: hasCell,
    fromReply: true)
  sim.haveDirective[seat] = true

proc forceActions*(sim: var SimServer, actions: openArray[int]) =
  ## Resolves one tick with EXACTLY these actions, bypassing the pilot -- so a
  ## test can assert upstream's rule for an action the deterministic pilot
  ## would never choose.
  var steps = newSeq[PilotStep](sim.world.robots.len)
  for slot in 0 ..< steps.len:
    steps[slot] = PilotStep(
      action: (if slot < actions.len: actions[slot] else: ActionNoop),
      outcome: orRunning)
  sim.resolveTick(steps)

proc scriptedEngine*(
  config: GameConfig, baselines: openArray[Baseline] = [
    blCourteous, blShuttle, blCourteous, blShuttle]
): DecisionEngine =
  result = initDecisionEngine(config)
  for seat in 0 ..< SeatCount:
    let baseline =
      if seat < baselines.len: baselines[seat] else: DefaultBaseline
    result.seats[seat].baseline = baseline
    result.seats[seat].label = $baseline

proc runScriptedEpisode*(
  config: GameConfig, replayPath = "",
  baselines: openArray[Baseline] = [
    blCourteous, blShuttle, blCourteous, blShuttle],
  joinSeats: set[uint8] = {0'u8, 1'u8, 2'u8, 3'u8}
): tuple[sim: SimServer, state: EpisodeState, bytes: string] =
  var engine = scriptedEngine(config, baselines)
  runHeadlessEpisode(config, engine, replayPath, joinSeats)

proc stripNimComments*(source: string): string =
  ## Source with `#`/`##` comments removed, so a token grep asks about CODE.
  var lines: seq[string]
  for line in source.splitLines():
    var inString = false
    var kept = ""
    var i = 0
    while i < line.len:
      let ch = line[i]
      if ch == '"':
        inString = not inString
      if ch == '#' and not inString:
        break
      kept.add(ch)
      inc i
    lines.add(kept)
  lines.join("\n")

proc manifestJson*(): JsonNode =
  parseJson(readRepoFile("coworld_manifest_template.json"))
