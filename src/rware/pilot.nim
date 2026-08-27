## The pilot: the deterministic map from one order to one RWARE action per
## robot, every tick. It is the ONLY producer of actions.
##
## There is NO randomness here at all. `path(u, goal)` is a breadth-first
## search, 4-connected, over the robot's BELIEVED grid; neighbours are expanded
## in the fixed order up, right, down, left, so the path is unique, and other
## robots are NOT obstacles in the plan (they move).
##
## PURE INTEGER (see warehouse.nim).

import upstream, warehouse, robots, directives, sim_state

type
  PilotStep* = object
    action*: int
    outcome*: OrderResult

proc shelfGoal*(sim: SimServer, shelf: int): int =
  ## Where a `fetch` steers. The design note names the shelf's HOME cell; a
  ## standing shelf is at its home until someone stows it somewhere else, and
  ## then the home cell holds nothing -- so the goal is the shelf's current
  ## standing cell, which IS its home in every unmoved case and keeps a
  ## re-requested, re-stowed shelf reachable instead of permanently
  ## `shelf_gone`.
  if shelf < 0 or shelf >= sim.world.shelves.len:
    return -1
  if sim.world.shelves[shelf].carrier >= 0:
    return sim.world.shelves[shelf].home
  sim.world.shelves[shelf].cell

proc parkCell*(sim: SimServer, seat: int): int =
  ## The idle park rule: the nearest aisle cell that is NOT in the workstation
  ## queue lane and NOT already held by another robot. Without it a robot that
  ## finished a delivery mid-turn would stand on the workstation and wall off
  ## the only lane to it; without the occupancy filter two idle robots would
  ## pick the same cell and the loser would grind against it forever.
  let
    wh = sim.world.wh
    me = sim.world.robots[seat].cell
    laneLeft = wh.width div 2 - 1
    laneRight = wh.width div 2
  result = -1
  var best = 0
  for cell in 0 ..< wh.highway.len:
    if not wh.isHighway(cell):
      continue
    let x = wh.cellX(cell)
    if x == laneLeft or x == laneRight:
      continue
    let occupant = sim.world.robotAtCell(cell)
    if occupant >= 0 and occupant != seat:
      continue
    let d = wh.chebyshev(me, cell)
    if result < 0 or d < best:
      result = cell
      best = d

proc goalCellOf*(sim: SimServer, seat: int): int =
  ## The cell the seat's current order steers to, or -1 when the order has no
  ## destination (`hold`, or a `stow` with no known free slot).
  let order = sim.directives[seat].order
  case order.kind
  of okFetch:
    shelfGoal(sim, order.shelf)
  of okDeliver:
    sim.world.wh.goals[clamp(order.station, 0, GoalCount - 1)]
  of okStow:
    if order.hasCell:
      let named = order.y * sim.world.wh.width + order.x
      if sim.world.wh.isStorage(named) and
          sim.world.standingShelfAt(named) < 0:
        named
      else:
        nearestSeenEmptySlot(sim.world, seat)
    else:
      nearestSeenEmptySlot(sim.world, seat)
  of okYield:
    nearestPassingPlace(sim.world, seat)
  of okHold:
    -1

proc rotationToward*(facing, wanted: int): int =
  ## `LEFT` or `RIGHT`, whichever is the shorter rotation. A 180-degree turn
  ## emits `RIGHT` twice, deterministically.
  if facing == wanted:
    return ActionNoop
  if turn(facing, ActionRight) == wanted:
    return ActionRight
  if turn(facing, ActionLeft) == wanted:
    return ActionLeft
  ActionRight

proc stepToward(sim: SimServer, seat, goal: int): tuple[action: int, ok: bool] =
  let
    robot = sim.world.robots[seat]
    wh = sim.world.wh
    passable =
      if robot.carrying >= 0: loadedPassable(sim.world, seat, goal)
      else: emptyPassable(sim.world)
    step = bfsFirstStep(wh, robot.cell, goal, passable)
  if step < 0:
    return (ActionNoop, false)
  let wanted = facingToward(robot.cell, step, wh.width)
  if robot.facing == wanted:
    ## FORWARD even when a robot is standing there: RWARE's chain rule lets a
    ## queue advance behind a mover, and refusing to try would forfeit that.
    (ActionForward, true)
  else:
    (rotationToward(robot.facing, wanted), true)

proc yieldStep(sim: SimServer, seat: int): tuple[action: int, arrived: bool] =
  ## `yield` is the ONE order that plans with the other robots as OBSTACLES.
  ## Everywhere else the pilot ignores them on purpose (RWARE's chain rule lets
  ## a queue advance behind a mover), but the whole point of yielding is to
  ## leave the contested lane, and the shortest route to the nearest junction
  ## is very often straight through the robot that is blocking you -- which
  ## would turn the release valve into part of the deadlock.
  ##
  ## Junctions are tried nearest first, ties by lowest cell index, and the
  ## first one reachable around the other robots wins. Bounded at 16 probes.
  let
    robot = sim.world.robots[seat]
    wh = sim.world.wh
  var passable =
    if robot.carrying >= 0: newSeq[bool](sim.world.robotAt.len)
    else: emptyPassable(sim.world)
  if robot.carrying >= 0:
    for cell in 0 ..< passable.len:
      passable[cell] = wh.isHighway(cell) or sim.world.seenEmpty[seat][cell]
  for cell in 0 ..< passable.len:
    let occupant = sim.world.robotAtCell(cell)
    if occupant >= 0 and occupant != seat:
      passable[cell] = false
  var probes = 0
  for goal in passingPlacesByDistance(sim.world, seat):
    if probes >= 16:
      break
    inc probes
    if sim.world.robotAtCell(goal) >= 0:
      continue
    let step = bfsFirstStep(wh, robot.cell, goal, passable)
    if step < 0:
      continue
    let wanted = facingToward(robot.cell, step, wh.width)
    if robot.facing == wanted:
      return (ActionForward, false)
    return (rotationToward(robot.facing, wanted), false)
  (ActionNoop, true)

proc chooseAction*(sim: SimServer, seat: int): PilotStep =
  ## One action index in upstream's five-way space, plus the honest report of
  ## how the order is going. Never leaves a robot unactuated.
  let
    order = sim.directives[seat].order
    robot = sim.world.robots[seat]
    wh = sim.world.wh
  result = PilotStep(action: ActionNoop, outcome: orRunning)

  # --- order-level refusals, reported and then parked ----------------------
  case order.kind
  of okFetch:
    if robot.carrying >= 0:
      result.outcome = orAlreadyLoaded
  of okDeliver, okStow:
    if robot.carrying < 0:
      result.outcome = orNotLoaded
  of okYield, okHold:
    discard

  var goal = -1
  if result.outcome == orRunning:
    if order.kind == okYield:
      let step = yieldStep(sim, seat)
      result.action = step.action
      if step.arrived:
        result.outcome = orDone
      return
    goal = goalCellOf(sim, seat)
    if order.kind == okStow and goal < 0:
      result.outcome = orNoFreeSlot
    elif order.kind == okFetch and goal < 0:
      result.outcome = orShelfGone

  if result.outcome != orRunning:
    ## Idle: park on the nearest aisle cell outside the queue lane and hold.
    ## `hold` is NOT idle -- it is a standing order to stand still, so it never
    ## reaches here: it keeps its `orRunning` outcome, has no goal cell, and
    ## falls through to the `goal < 0` return below as NOOP, every tick.
    let park = parkCell(sim, seat)
    if park < 0 or robot.cell == park:
      return
    let step = stepToward(sim, seat, park)
    result.action = step.action
    return

  if goal < 0:
    return

  # --- on the goal cell: the order's terminal action ------------------------
  if robot.cell == goal:
    case order.kind
    of okFetch:
      if sim.world.standingShelfAt(goal) == order.shelf:
        result.action = ActionToggleLoad
      else:
        result.outcome = orShelfGone
    of okStow:
      if wh.isStorage(robot.cell) and sim.world.standingShelfAt(robot.cell) < 0:
        result.action = ActionToggleLoad
      else:
        result.outcome = orNoFreeSlot
    of okDeliver:
      ## The engine credits the delivery when the shelf arrives; standing on
      ## the pad is the whole action.
      discard
    of okYield:
      result.outcome = orDone
    of okHold:
      discard
    return

  # --- otherwise: step toward the goal -------------------------------------
  let step = stepToward(sim, seat, goal)
  if not step.ok:
    result.outcome = orNoPath
    return
  result.action = step.action

proc chooseActions*(sim: SimServer): seq[PilotStep] =
  ## One step per robot, in ascending slot, from the SNAPSHOT world -- no rule
  ## in `resolveTick` reads a partially updated board.
  result = newSeq[PilotStep](sim.world.robots.len)
  for slot in 0 ..< sim.world.robots.len:
    result[slot] = chooseAction(sim, slot)
