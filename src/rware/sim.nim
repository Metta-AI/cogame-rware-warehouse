## The step loop: the whole physics of the game and nothing else mutates the
## world. Re-exports the sim modules, so `import rware/sim` sees everything --
## the starter's layout, kept, and the reason the SAME module compiles natively
## for the server and to wasm for the replay viewer.
##
## PURE INTEGER (see warehouse.nim). The resolution order is pinned by the
## design note and by upstream:
##   1. snapshot   2. choose   3. veto loaded moves   4. move graph
##   5. apply      6. rebuild  7. deliver             8. jam
##   9. hash      10. end

import sim_types, sim_config, upstream, warehouse, robots, jam, events,
  directives, sim_state, pilot, baselines

export sim_types, sim_config, upstream, warehouse, robots, jam, events,
  directives, sim_state, pilot, baselines

proc applyOrders*(sim: var SimServer, seat: int, directive: RobotDirective) =
  ## Installs one seat's directive. A seat whose reply carried no `verb` keeps
  ## the order it had, so `fromReply == false` leaves the standing order alone.
  if seat < 0 or seat >= SeatCount:
    return
  let previous = sim.directives[seat].order
  var next = directive
  if not next.order.fromReply:
    if sim.haveDirective[seat]:
      next.order = previous
    else:
      ## Turn 1, and the reply named no verb. The default is NOT `hold`: the
      ## note's ladder is "this turn's, else last turn's, else COURTEOUS's"
      ## (design.md:169-170, :400-401), and a robot standing still through the
      ## opening turn is 20 ticks of a 500-tick shift spent not fetching.
      next.order = courteousDirective(sim, seat).order
  sim.directives[seat] = next
  sim.haveDirective[seat] = true
  if seat < sim.world.robots.len:
    if next.order.kind == previous.kind and
        next.order.shelf == previous.shelf and
        next.order.station == previous.station:
      inc sim.world.robots[seat].orderAgeTurns
    else:
      sim.world.robots[seat].orderAgeTurns = 1
      sim.world.robots[seat].lastResult = orRunning

proc evaluateEnd*(sim: var SimServer) =
  ## The one end condition the sim owns: the tick cap. There is no early win,
  ## no early loss and no inactivity termination -- a totally deadlocked fleet
  ## plays out its 500 ticks with the jam flag lit and scores 0.
  if sim.phase != Playing:
    return
  if sim.tick >= sim.config.maxTicks:
    sim.bankGame(EndRuleTickCap)

proc applyStop*(sim: var SimServer, endRule: string) =
  ## The load-bearing stop. A wall-clock or fault stop cannot be re-derived
  ## from sim state, so it is written to the replay as one record and applied
  ## by THIS proc on record AND on playback -- which is what keeps the hash
  ## chain clean at the stop tick (the particle-worlds scar).
  if sim.phase == GameOver:
    return
  sim.bankGame(endRule)

proc requestedCell(sim: SimServer, slot, action: int): int =
  ## Upstream's `req_location`, clamped to the board: a wall bump therefore
  ## targets the robot's own cell and becomes a self-edge in the move graph.
  if action != ActionForward:
    sim.world.robots[slot].cell
  else:
    sim.world.wh.stepCell(sim.world.robots[slot].cell,
      sim.world.robots[slot].facing)

proc commitMovers(sim: SimServer, target: openArray[int]): seq[bool] =
  ## Upstream's collision resolution, with the two implementation-defined
  ## networkx choices PINNED (documented divergence 1):
  ##
  ## Each robot contributes one edge `own cell -> requested cell`, so the graph
  ## is a FUNCTIONAL graph (out-degree <= 1) and each weakly-connected
  ## component holds at most one cycle.
  ##
  ##  * a cycle of length 2 (a head-on swap) moves nobody in that component;
  ##  * any longer cycle -- including a self-edge, a length-1 cycle -- moves
  ##    every robot standing on a node of that cycle and nothing else;
  ##  * an acyclic component moves the robots on its LONGEST directed path,
  ##    ties broken toward the path whose START NODE has the lowest cell index.
  ##
  ## Cells are ordered by index `y*W + x`; the cycle search starts from the
  ## lowest-indexed node of the component and visits successors in ascending
  ## index order (there is at most one).
  let
    count = sim.world.robots.len
    cells = sim.world.wh.width * sim.world.wh.height
  result = newSeq[bool](count)
  var
    outEdge = newSeq[int](cells)     ## cell -> target cell, or -1
    robotOn = newSeq[int](cells)     ## cell -> robot slot, or -1
    inGraph = newSeq[bool](cells)
  for cell in 0 ..< cells:
    outEdge[cell] = -1
    robotOn[cell] = -1
  for slot in 0 ..< count:
    let start = sim.world.robots[slot].cell
    outEdge[start] = target[slot]
    robotOn[start] = slot
    inGraph[start] = true
    inGraph[target[slot]] = true

  # Weakly-connected components by union-find over the edges.
  var parent = newSeq[int](cells)
  for cell in 0 ..< cells:
    parent[cell] = cell

  proc find(parent: var seq[int], cell: int): int =
    var root = cell
    while parent[root] != root:
      root = parent[root]
    var walk = cell
    while parent[walk] != walk:
      let next = parent[walk]
      parent[walk] = root
      walk = next
    root

  for cell in 0 ..< cells:
    if outEdge[cell] < 0:
      continue
    let
      a = find(parent, cell)
      b = find(parent, outEdge[cell])
    if a != b:
      parent[max(a, b)] = min(a, b)

  var handled = newSeq[bool](cells)
  for root in 0 ..< cells:
    if not inGraph[root] or handled[root] or find(parent, root) != root:
      continue
    var members: seq[int]
    for cell in 0 ..< cells:
      if inGraph[cell] and find(parent, cell) == root:
        members.add(cell)
        handled[cell] = true
    if members.len == 0:
      continue
    # --- cycle search from the lowest-indexed node ---------------------------
    var
      onPath = newSeq[int](cells)
      path: seq[int]
      walk = members[0]
      cycleStart = -1
    for cell in 0 ..< cells:
      onPath[cell] = -1
    while walk >= 0 and outEdge[walk] >= 0:
      if onPath[walk] >= 0:
        cycleStart = onPath[walk]
        break
      onPath[walk] = path.len
      path.add(walk)
      walk = outEdge[walk]
    if cycleStart >= 0:
      let cycleLen = path.len - cycleStart
      if cycleLen == 2:
        ## [A] <-> [B] is physically impossible, so nobody in the component
        ## moves.
        continue
      for i in cycleStart ..< path.len:
        let slot = robotOn[path[i]]
        if slot >= 0:
          result[slot] = true
      continue
    # --- acyclic: the longest directed path ----------------------------------
    var depth = newSeq[int](cells)
    for cell in members:
      depth[cell] = -1

    proc chainLength(
      depth: var seq[int], outEdge: seq[int], cell: int
    ): int =
      if depth[cell] >= 0:
        return depth[cell]
      if outEdge[cell] < 0:
        depth[cell] = 1
      else:
        depth[cell] = 1 + chainLength(depth, outEdge, outEdge[cell])
      depth[cell]

    var
      bestStart = -1
      bestLen = 0
    for cell in members:
      if outEdge[cell] < 0:
        continue
      let length = chainLength(depth, outEdge, cell)
      if length > bestLen or (length == bestLen and bestStart < 0):
        bestLen = length
        bestStart = cell
    if bestStart < 0:
      continue
    var node = bestStart
    while node >= 0:
      let slot = robotOn[node]
      if slot >= 0:
        result[slot] = true
      node = outEdge[node]

proc resolveTick*(sim: var SimServer, steps: seq[PilotStep]) =
  ## Steps 1-10 of one RWARE cycle, given the pilot's chosen actions. Split out
  ## from `step` so a test can force an action the deterministic pilot would
  ## never choose and assert upstream's rule directly.
  if sim.phase != Playing:
    return
  inc sim.tick
  inc sim.episodeTick
  sim.lastLoads = @[]
  sim.lastDeliveries = @[]
  sim.lastStows = @[]
  sim.jamStarted = false
  sim.jamCleared = false

  let count = sim.world.robots.len
  var
    action = newSeq[int](count)
    requestedForward = newSeq[bool](count)
    startCell = newSeq[int](count)
  for slot in 0 ..< count:
    action[slot] = steps[slot].action
    requestedForward[slot] = action[slot] == ActionForward
    startCell[slot] = sim.world.robots[slot].cell
    if steps[slot].outcome != orRunning:
      sim.world.robots[slot].lastResult = steps[slot].outcome

  # --- 3. veto impossible loaded moves (upstream, verbatim) -----------------
  for slot in 0 ..< count:
    if action[slot] != ActionForward or sim.world.robots[slot].carrying < 0:
      continue
    let target = requestedCell(sim, slot, ActionForward)
    if target == sim.world.robots[slot].cell:
      continue
    let shelfThere = sim.world.standingShelfAt(target)
    if shelfThere < 0:
      continue
    let occupant = sim.world.robotAtCell(target)
    if occupant >= 0 and sim.world.robots[occupant].carrying >= 0:
      ## The cell holds a robot that is itself carrying, so the shelf there is
      ## not standing after all.
      continue
    action[slot] = ActionNoop

  # --- 4. the move graph ----------------------------------------------------
  var target = newSeq[int](count)
  for slot in 0 ..< count:
    target[slot] = requestedCell(sim, slot, action[slot])
  let committed = commitMovers(sim, target)

  # --- 5. apply, ascending slot --------------------------------------------
  for slot in 0 ..< count:
    case action[slot]
    of ActionForward:
      if committed[slot] and target[slot] != sim.world.robots[slot].cell:
        sim.world.robots[slot].cell = target[slot]
        let carried = sim.world.robots[slot].carrying
        if carried >= 0:
          sim.world.shelves[carried].cell = target[slot]
    of ActionLeft, ActionRight:
      sim.world.robots[slot].facing =
        turn(sim.world.robots[slot].facing, action[slot])
    of ActionToggleLoad:
      let cell = sim.world.robots[slot].cell
      if sim.world.robots[slot].carrying < 0:
        let shelf = sim.world.standingShelfAt(cell)
        if shelf >= 0:
          sim.world.robots[slot].carrying = shelf
          sim.world.shelves[shelf].carrier = slot
          sim.world.shelfAt[cell] = -1
          sim.world.robots[slot].lastResult = orDone
          sim.lastLoads.add(
            DeliveryMark(tick: sim.tick, slot: slot, shelf: shelf,
              station: -1))
          sim.emitEvent(Load, source = slot, target = shelf, amount = cell)
      elif not sim.world.wh.isHighway(cell):
        ## Unloading is refused on every highway cell -- the delivery row and
        ## the queue lane included.
        let shelf = sim.world.robots[slot].carrying
        sim.world.robots[slot].carrying = -1
        sim.world.shelves[shelf].carrier = -1
        sim.world.shelves[shelf].cell = cell
        sim.world.shelfAt[cell] = shelf
        inc sim.world.robots[slot].stowed
        sim.world.robots[slot].lastResult = orDone
        sim.lastStows.add(
          DeliveryMark(tick: sim.tick, slot: slot, shelf: shelf,
            station: -1))
        sim.emitEvent(Stow, source = slot, target = shelf, amount = cell)
    else:
      discard

  # --- 6. rebuild the occupancy layers -------------------------------------
  sim.world.rebuildLayers()

  # --- 7. deliveries, W1 then W2 -------------------------------------------
  for station in 0 ..< GoalCount:
    let goal = sim.world.wh.goals[station]
    var shelfHere = -1
    for id in 0 ..< sim.world.shelves.len:
      if sim.world.shelves[id].cell == goal:
        shelfHere = id
        break
    if shelfHere < 0 or not sim.world.requested[shelfHere]:
      continue
    let slot = sim.world.robotAtCell(goal)
    if slot >= 0:
      inc sim.world.robots[slot].delivered
      sim.world.robots[slot].lastResult = orDone
    inc sim.world.teamDelivered
    sim.lastDeliveries.add(
      DeliveryMark(tick: sim.tick, slot: slot, shelf: shelfHere,
        station: station))
    sim.emitEvent(Deliver, source = slot, target = shelfHere,
      amount = sim.world.teamDelivered)
    ## Remove from the board and refill that queue slot with a shelf drawn by
    ## the REQUEST stream -- a pure function of (seed, deliveries so far).
    ##
    ## The draw comes FIRST, exactly as upstream orders it
    ## (warehouse.py:915-917: `candidates = [s for s in self.shelfs if s not in
    ## self.request_queue]` is evaluated while the delivered shelf is still in
    ## the queue). The delivered shelf is therefore not a candidate for its own
    ## replacement, and the candidate set has upstream's cardinality on every
    ## refill rather than one more.
    let replacement = sim.world.refillDraw(sim.config.seed, sim.refillDraws)
    inc sim.refillDraws
    sim.world.requested[shelfHere] = false
    for k in 0 ..< sim.world.requestQueue.len:
      if sim.world.requestQueue[k] == shelfHere:
        if replacement >= 0:
          sim.world.requestQueue[k] = replacement
          sim.world.requested[replacement] = true
        break

  # --- 8. jam detection -----------------------------------------------------
  for slot in 0 ..< count:
    let moved = sim.world.robots[slot].cell != startCell[slot]
    if requestedForward[slot] and not moved:
      inc sim.world.robots[slot].stuck
      inc sim.world.robots[slot].blockedMoves
      inc sim.world.robots[slot].blockedThisTurn
      sim.emitEvent(Blocked, source = slot)
    else:
      sim.world.robots[slot].stuck = 0
  var wanted = newSeq[int](count)
  for slot in 0 ..< count:
    wanted[slot] =
      if requestedForward[slot]:
        sim.world.wh.stepCell(startCell[slot], sim.world.robots[slot].facing)
      else:
        sim.world.robots[slot].cell
  let members = detectJam(sim.world, wanted, sim.config.jamTicks)
  let transition = sim.jamState.updateJam(members, sim.tick)
  sim.jamStarted = transition.started
  sim.jamCleared = transition.cleared
  sim.jamClearedTicks = transition.clearedTicks
  ## CLEAR FIRST: a membership change closes the jam that was being shown and
  ## opens a new one on the same tick, and the pair has to read
  ## jam -> jamclear -> jam rather than jam -> jam.
  if transition.cleared:
    sim.emitEvent(JamClear, amount = transition.clearedTicks)
  if transition.started:
    sim.emitEvent(Jam, amount = members.len)

  # --- the per-seat sensor memory the pilot plans on ------------------------
  for slot in 0 ..< count:
    sim.world.noteVisibleSlots(slot)

  # --- 10. end conditions ---------------------------------------------------
  sim.evaluateEnd()

proc step*(sim: var SimServer) =
  ## One RWARE cycle: choose from the snapshot, then resolve.
  if sim.phase != Playing:
    return
  resolveTick(sim, chooseActions(sim))

proc advanceFrame*(sim: var SimServer) =
  ## One frame of the whole game, whatever phase it is in. The live server and
  ## the replay runtime both drive THIS proc, so playback and recording can
  ## never run two different loops.
  case sim.phase
  of Lobby:
    inc sim.lobbyTicks
  of Playing:
    sim.step()
  of GameOver:
    inc sim.gameOverHold
