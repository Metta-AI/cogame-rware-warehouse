## The two scripted baselines, both shipped as fillers. `courteous` is also the
## server-side fallback -- the decision engine imports THIS proc rather than
## duplicating it, so the two can never drift (tests/test_rware_pilot.nim).
##
## Both emit the same RobotDirective an LLM does, through the same validator,
## which is what makes the bounded-orders test meaningful. Neither ever emits
## `say` or `notes`: they are the robots whose policies you do not control and
## who will not talk to you, which is precisely the ad-hoc coordination problem
## the idea names.
##
## PURE INTEGER (see warehouse.nim).

import std/strutils
import sim_types, warehouse, robots, directives, sim_state

type
  Baseline* = enum
    blShuttle = "shuttle"
    blCourteous = "courteous"

  BaselineParams* = object
    yieldAfter*: int
    penalty*: int
    stowClearance*: int

const
  DefaultBaselineParams* = BaselineParams(
    # yieldAfter: blocked ticks since the last turn that make a robot back off.
    # penalty: the cost a contested shelf carries in the fetch choice.
    # stowClearance: how far from the workstation queue lane a stow prefers.
    yieldAfter: 4,
    penalty: 4,
    stowClearance: 2
  )
    ## Not guessed: tools/tune_baselines.nim sweeps the three head to head and
    ## tools/ci/baseline_tuning.json records the pick;
    ## tests/test_rware_tuning.nim asserts the shipped defaults still equal it.
    ## `yieldAfter` was re-swept from 6 to 4 when the pilot stopped parking a
    ## credited robot on the workstation: with the pad clearing itself, backing
    ## off sooner is strictly better for fleet throughput at every horizon the
    ## sweep runs (see vendor/PATCHES.md divergence 19).

  DefaultBaseline* = blCourteous
    ## Anything unrecognised is the published default (the starter's rule).

proc parseBaseline*(text: string): Baseline =
  let key = text.strip().toLowerAscii()
  for baseline in Baseline:
    if $baseline == key:
      return baseline
  DefaultBaseline

proc queueLaneDistance(wh: Warehouse, cell: int): int =
  let
    x = wh.cellX(cell)
    laneLeft = wh.width div 2 - 1
    laneRight = wh.width div 2
  min(abs(x - laneLeft), abs(x - laneRight))

proc pathCost(sim: SimServer, seat, goal: int): int =
  ## BFS distance over the seat's believed grid, or a large sentinel when the
  ## goal is unreachable. Integer only; the sentinel is deliberately larger
  ## than any board diameter.
  let robot = sim.world.robots[seat]
  let passable =
    if robot.carrying >= 0: loadedPassable(sim.world, seat, goal)
    else: emptyPassable(sim.world)
  let d = bfsDistance(sim.world.wh, robot.cell, goal, passable)
  if d < 0: 1_000_000 else: d

proc nearerStation(sim: SimServer, seat: int): int =
  ## The nearer workstation by path length, ties to W1.
  let
    a = pathCost(sim, seat, sim.world.wh.goals[0])
    b = pathCost(sim, seat, sim.world.wh.goals[1])
  if b < a: 1 else: 0

proc visibleRobotsNear(sim: SimServer, seat, cell: int): int =
  ## How many OTHER robots this seat can see standing within its sensor range
  ## of `cell`.
  for slot in 0 ..< sim.world.robots.len:
    if slot == seat:
      continue
    if not sim.world.visibleTo(seat, sim.world.robots[slot].cell):
      continue
    if sim.world.wh.chebyshev(sim.world.robots[slot].cell, cell) <=
        sim.world.sensorRange:
      inc result

proc stowOrder(
  sim: SimServer, seat: int, params: BaselineParams, clearance: int
): RobotOrder =
  ## `stow` with explicit coordinates when a clear enough slot is known, else
  ## the bare order, which the pilot resolves to the nearest seen-empty slot.
  result = RobotOrder(
    kind: okStow, shelf: -1, station: 0, x: -1, y: -1, hasCell: false,
    fromReply: true)
  let slots = freeSlotsNear(sim.world, seat, MaxFreeSlotsReported)
  var chosen = -1
  for cell in slots:
    if queueLaneDistance(sim.world.wh, cell) >= clearance:
      chosen = cell
      break
  if chosen < 0 and slots.len > 0:
    chosen = slots[0]
  if chosen >= 0:
    result.x = sim.world.wh.cellX(chosen)
    result.y = sim.world.wh.cellY(chosen)
    result.hasCell = true

proc fetchOrder(
  sim: SimServer, seat: int, params: BaselineParams, contention: bool
): RobotOrder =
  ## The requested shelf with the lowest cost, ties by lowest shelf id.
  ## `contention` adds `params.penalty` when a visible other robot is strictly
  ## closer to that shelf than this robot is -- so `courteous` leaves a shelf
  ## somebody else is already nearly on top of.
  ##
  ## The design note writes this cost as `path - contentionPenalty`; minimising
  ## that would PREFER a contested shelf, which is the opposite of the rule the
  ## same paragraph describes, so the port adds the penalty (vendor/PATCHES.md
  ## divergence 8).
  result = RobotOrder(
    kind: okHold, shelf: -1, station: 0, x: -1, y: -1, fromReply: true)
  var best = 0
  for id in sim.world.requestQueue:
    if id < 0 or id >= sim.world.shelves.len:
      continue
    if sim.world.shelves[id].carrier >= 0:
      continue
    let standing = sim.world.shelves[id].cell
      ## where the shelf IS, which is its home until somebody re-stows it --
      ## the same cell `pilot.shelfGoal` steers a `fetch` to
      ## (vendor/PATCHES.md divergence 12)
    var cost = pathCost(sim, seat, standing)
    if contention:
      let mine = sim.world.wh.chebyshev(sim.world.robots[seat].cell, standing)
      for other in 0 ..< sim.world.robots.len:
        if other == seat:
          continue
        if not sim.world.visibleTo(seat, sim.world.robots[other].cell):
          continue
        if sim.world.wh.chebyshev(sim.world.robots[other].cell, standing) <
            mine:
          cost += params.penalty
          break
    if result.kind == okHold or cost < best or
        (cost == best and id < result.shelf):
      ## Ties by LOWEST SHELF ID (design.md:638, :652), not by the shelf's
      ## position in the request queue: the queue's order is the draw order,
      ## which would make the choice depend on delivery history rather than on
      ## the board in front of the robot.
      result = RobotOrder(
        kind: okFetch, shelf: id, station: 0, x: -1, y: -1, fromReply: true)
      best = cost

proc shuttleDirective*(
  sim: SimServer, seat: int, params = DefaultBaselineParams
): RobotDirective =
  ## Pure greed, no jam handling. It is short, it is a real opponent to jam
  ## against, and it is the control that answers "did the LLM actually
  ## coordinate?".
  result = defaultDirective()
  result.source = dsScripted
  if seat >= sim.world.robots.len:
    return
  let carried = sim.world.robots[seat].carrying
  if carried >= 0 and not sim.world.requested[carried]:
    result.order = stowOrder(sim, seat, params, 0)
  elif carried >= 0:
    result.order = RobotOrder(
      kind: okDeliver, shelf: -1, station: nearerStation(sim, seat),
      x: -1, y: -1, fromReply: true)
  else:
    result.order = fetchOrder(sim, seat, params, contention = false)

proc courteousDirective*(
  sim: SimServer, seat: int, params = DefaultBaselineParams
): RobotDirective =
  ## 1. blocked for `yieldAfter` ticks and a LOWER-slot visible robot is also
  ##    blocked -> `yield` (the tie-break by slot index means exactly one robot
  ##    in any pair yields, which is what actually clears a jam);
  ## 2. carrying a delivered shelf -> `stow`, preferring a slot `stowClearance`
  ##    cells clear of the workstation queue lane;
  ## 3. carrying a requested shelf -> `deliver` to the workstation with fewer
  ##    visible robots near it, ties to the nearer one, then to W1;
  ## 4. empty -> `fetch` the cheapest requested shelf, contested shelves
  ##    penalised.
  result = defaultDirective()
  result.source = dsScripted
  if seat >= sim.world.robots.len:
    return
  if sim.world.robots[seat].blockedLastTurn >= params.yieldAfter:
    ## The note's rule: yield when a visible robot with a LOWER slot index is
    ## also blocked, so exactly one robot in any pair backs off. Plus the
    ## release valve it needs to be complete (vendor/PATCHES.md divergence 9):
    ## the lower-slot robot in a standoff may be a `shuttle`, which never
    ## yields, and then nobody does and the aisle is dead for the rest of the
    ## episode. A robot blocked for TWICE `yieldAfter` therefore yields
    ## whatever its slot -- late enough that the slot tie-break still decides
    ## every ordinary pair.
    var lowerBlocked = false
    for other in 0 ..< seat:
      if sim.world.robots[other].blockedLastTurn >= params.yieldAfter and
          sim.world.visibleTo(seat, sim.world.robots[other].cell):
        lowerBlocked = true
        break
    if lowerBlocked or
        sim.world.robots[seat].blockedLastTurn >= 2 * params.yieldAfter:
      result.order = RobotOrder(
        kind: okYield, shelf: -1, station: 0, x: -1, y: -1, fromReply: true)
      return
  let carried = sim.world.robots[seat].carrying
  if carried >= 0 and not sim.world.requested[carried]:
    result.order = stowOrder(sim, seat, params, params.stowClearance)
  elif carried >= 0:
    let
      nearA = visibleRobotsNear(sim, seat, sim.world.wh.goals[0])
      nearB = visibleRobotsNear(sim, seat, sim.world.wh.goals[1])
    var station = nearerStation(sim, seat)
    if nearA < nearB: station = 0
    elif nearB < nearA: station = 1
    result.order = RobotOrder(
      kind: okDeliver, shelf: -1, station: station, x: -1, y: -1,
      fromReply: true)
  else:
    result.order = fetchOrder(sim, seat, params, contention = true)

proc scriptedDirective*(
  sim: SimServer, seat: int, baseline: Baseline,
  params = DefaultBaselineParams
): RobotDirective =
  case baseline
  of blShuttle: shuttleDirective(sim, seat, params)
  of blCourteous: courteousDirective(sim, seat, params)

proc fallbackDirective*(
  sim: SimServer, seat: int, params = DefaultBaselineParams
): RobotDirective =
  ## The server-side fallback IS the courteous baseline -- same proc, never a
  ## copy (tests/test_rware_pilot.nim asserts they agree order for order).
  var directive = courteousDirective(sim, seat, params)
  directive.source = dsFallback
  directive
