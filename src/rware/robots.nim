## The robots, the shelves, the request board and per-seat visibility.
##
## Flat arrays and two occupancy layers, exactly upstream's `_LAYER_AGENTS` /
## `_LAYER_SHELFS` split: `shelfAt` records only STANDING shelves, so a shelf
## on a robot's forks is invisible to the loaded-move veto and to `TOGGLE_LOAD`.
##
## PURE INTEGER (see warehouse.nim).

import warehouse

type
  OrderResult* = enum
    orRunning = "running"
    orDone = "done"
    orShelfGone = "shelf_gone"
    orNoPath = "no_path"
    orNoFreeSlot = "no_free_slot"
    orNotLoaded = "not_loaded"
    orAlreadyLoaded = "already_loaded"

  Robot* = object
    cell*: int
    facing*: int              ## DirUp / DirDown / DirLeft / DirRight
    carrying*: int            ## shelf index, or -1
    stuck*: int               ## consecutive ticks that wanted FORWARD and failed
    blockedMoves*: int        ## episode total
    blockedThisTurn*: int     ## since the last command turn
    blockedLastTurn*: int     ## reported in the observation
    delivered*: int
    stowed*: int
    lastResult*: OrderResult
    orderAgeTurns*: int

  Shelf* = object
    home*: int                ## the storage cell it was placed in at reset
    cell*: int                ## where it is now
    carrier*: int             ## robot slot carrying it, or -1

  World* = object
    wh*: Warehouse
    robots*: seq[Robot]
    shelves*: seq[Shelf]
    robotAt*: seq[int]        ## cell -> robot slot, or -1
    shelfAt*: seq[int]        ## cell -> STANDING shelf index, or -1
    requestQueue*: seq[int]   ## shelf indices, queue order
    requested*: seq[bool]     ## shelf index -> is it on the board?
    seenEmpty*: seq[seq[bool]] ## per seat: storage cell seen empty this episode
    teamDelivered*: int
    sensorRange*: int

proc splitMix64(state: uint64): uint64 =
  ## A pure, integer, platform-independent mixer. Two RNG streams are derived
  ## from it and neither ever consumes shared state: a draw is a function of
  ## `(seed, index)` alone, so the request stream cannot be steered by which
  ## seat delivered (the anti-collusion pin).
  var z = state + 0x9e3779b97f4a7c15'u64
  z = (z xor (z shr 30)) * 0xbf58476d1ce4e5b9'u64
  z = (z xor (z shr 27)) * 0x94d049bb133111eb'u64
  z xor (z shr 31)

proc streamDraw*(seed, stream, index, bound: int): int =
  ## The `index`-th draw of `stream`, uniform over `[0, bound)`.
  if bound <= 0:
    return 0
  let mixed = splitMix64(
    cast[uint64](int64(seed)) xor
    (cast[uint64](int64(stream)) * 0xd1342543de82ef95'u64) xor
    (cast[uint64](int64(index)) * 0xa24baed4963ee407'u64))
  int(mixed mod uint64(bound))

const
  StreamSetup* = 1
  StreamRequest* = 2

proc clearLayers(world: var World) =
  for i in 0 ..< world.robotAt.len:
    world.robotAt[i] = -1
    world.shelfAt[i] = -1

proc rebuildLayers*(world: var World) =
  ## Both occupancy layers, from the robots' and shelves' current positions.
  ## A carried shelf is NOT standing, so it never enters `shelfAt`.
  world.clearLayers()
  for slot in 0 ..< world.robots.len:
    world.robotAt[world.robots[slot].cell] = slot
  for id in 0 ..< world.shelves.len:
    if world.shelves[id].carrier < 0 and world.shelves[id].cell >= 0:
      world.shelfAt[world.shelves[id].cell] = id

proc initWorld*(
  shelfColumns, shelfRows, columnHeight, agents, queueSize, sensorRange,
  seed: int
): World =
  ## Reset: shelves on every non-highway cell, `agents` distinct uniformly
  ## random spawn cells with uniformly random facings, and `queueSize` distinct
  ## requested shelves -- upstream's own reset, drawn from `StreamSetup`.
  result.wh = initWarehouse(shelfColumns, shelfRows, columnHeight)
  result.sensorRange = sensorRange
  let cells = result.wh.width * result.wh.height
  result.robotAt = newSeq[int](cells)
  result.shelfAt = newSeq[int](cells)
  for id in 0 ..< result.wh.shelfCount():
    let cell = result.wh.slotCell[id]
    result.shelves.add(Shelf(home: cell, cell: cell, carrier: -1))
  result.requested = newSeq[bool](result.shelves.len)
  # Spawn: distinct cells drawn without replacement, in draw order.
  var pool = newSeq[int](cells)
  for i in 0 ..< cells:
    pool[i] = i
  var remaining = cells
  for slot in 0 ..< agents:
    let pick = streamDraw(seed, StreamSetup, slot, remaining)
    let cell = pool[pick]
    pool[pick] = pool[remaining - 1]
    dec remaining
    let facing = streamDraw(seed, StreamSetup, 1000 + slot, 4)
    result.robots.add(Robot(
      cell: cell, facing: facing, carrying: -1, lastResult: orRunning))
  # The initial request board: distinct shelves, without replacement.
  var shelfPool = newSeq[int](result.shelves.len)
  for i in 0 ..< result.shelves.len:
    shelfPool[i] = i
  var left = result.shelves.len
  for k in 0 ..< min(queueSize, result.shelves.len):
    let pick = streamDraw(seed, StreamSetup, 2000 + k, left)
    let id = shelfPool[pick]
    shelfPool[pick] = shelfPool[left - 1]
    dec left
    result.requestQueue.add(id)
    result.requested[id] = true
  result.seenEmpty = newSeq[seq[bool]](agents)
  for slot in 0 ..< agents:
    result.seenEmpty[slot] = newSeq[bool](cells)
  result.rebuildLayers()

proc robotAtCell*(world: World, cell: int): int {.inline.} =
  if cell < 0 or cell >= world.robotAt.len: -1 else: world.robotAt[cell]

proc standingShelfAt*(world: World, cell: int): int {.inline.} =
  if cell < 0 or cell >= world.shelfAt.len: -1 else: world.shelfAt[cell]

proc refillDraw*(world: World, seed, drawIndex: int): int =
  ## The `drawIndex`-th request refill: a shelf drawn uniformly from those not
  ## currently on the board. `drawIndex` is the number of deliveries so far, so
  ## the draw depends only on `(seed, k)` and never on WHICH seat delivered.
  var candidates: seq[int]
  for id in 0 ..< world.shelves.len:
    if not world.requested[id]:
      candidates.add(id)
  if candidates.len == 0:
    return -1
  candidates[streamDraw(seed, StreamRequest, drawIndex, candidates.len)]

proc chebyshev*(wh: Warehouse, a, b: int): int {.inline.} =
  let
    dx = abs(wh.cellX(a) - wh.cellX(b))
    dy = abs(wh.cellY(a) - wh.cellY(b))
  max(dx, dy)

proc visibleTo*(world: World, viewer, cell: int): bool {.inline.} =
  ## A cell is visible to a seat iff it is within Chebyshev `sensorRange` of
  ## that seat's OWN robot. Upstream's sensor window, widened from 1 to 3
  ## (documented divergence 3) because a seat plans 20 ticks ahead.
  world.wh.chebyshev(world.robots[viewer].cell, cell) <= world.sensorRange

proc noteVisibleSlots*(world: var World, viewer: int) =
  ## The per-seat "seen empty" memory the pilot plans a loaded route on. An
  ## unseen storage cell is assumed to hold a shelf -- conservative, so a
  ## loaded robot plans along the aisles until it has actually looked.
  let me = world.robots[viewer].cell
  let range = world.sensorRange
  let
    x0 = max(0, world.wh.cellX(me) - range)
    x1 = min(world.wh.width - 1, world.wh.cellX(me) + range)
    y0 = max(0, world.wh.cellY(me) - range)
    y1 = min(world.wh.height - 1, world.wh.cellY(me) + range)
  for y in y0 .. y1:
    for x in x0 .. x1:
      let cell = y * world.wh.width + x
      if world.wh.isStorage(cell):
        world.seenEmpty[viewer][cell] = world.shelfAt[cell] < 0

proc loadedPassable*(world: World, viewer, goal: int): seq[bool] =
  ## The believed grid a LOADED robot plans over: every aisle cell, the
  ## destination, and the storage cells this seat has SEEN to be empty.
  result = newSeq[bool](world.robotAt.len)
  for cell in 0 ..< result.len:
    result[cell] = world.wh.isHighway(cell) or world.seenEmpty[viewer][cell]
  if goal >= 0 and goal < result.len:
    result[goal] = true

proc emptyPassable*(world: World): seq[bool] =
  ## An EMPTY robot drives under standing shelves, so every cell is passable.
  result = newSeq[bool](world.robotAt.len)
  for cell in 0 ..< result.len:
    result[cell] = true

proc freeSlotsNear*(world: World, viewer, limit: int): seq[int] =
  ## At most `limit` visible empty storage cells, NEAREST FIRST by Chebyshev
  ## distance, ties by lowest cell index.
  let me = world.robots[viewer].cell
  var candidates: seq[int]
  for cell in 0 ..< world.shelfAt.len:
    if world.wh.isStorage(cell) and world.shelfAt[cell] < 0 and
        world.visibleTo(viewer, cell):
      candidates.add(cell)
  # Insertion sort: at most (2r+1)^2 entries, and a stable dependency-free sort
  # keeps the ordering identical on every platform.
  for i in 1 ..< candidates.len:
    let cur = candidates[i]
    let curKey = world.wh.chebyshev(me, cur)
    var j = i - 1
    while j >= 0:
      let otherKey = world.wh.chebyshev(me, candidates[j])
      if otherKey > curKey or (otherKey == curKey and candidates[j] > cur):
        candidates[j + 1] = candidates[j]
        dec j
      else:
        break
    candidates[j + 1] = cur
  for i in 0 ..< min(limit, candidates.len):
    result.add(candidates[i])

proc nearestSeenEmptySlot*(world: World, viewer: int): int =
  ## The nearest storage cell this seat has seen empty AND which is still empty
  ## if it can see it now, ties by lowest cell index. -1 when it knows of none.
  let me = world.robots[viewer].cell
  result = -1
  var best = 0
  for cell in 0 ..< world.shelfAt.len:
    if not world.wh.isStorage(cell) or not world.seenEmpty[viewer][cell]:
      continue
    if world.visibleTo(viewer, cell) and world.shelfAt[cell] >= 0:
      continue
    let d = world.wh.chebyshev(me, cell)
    if result < 0 or d < best:
      result = cell
      best = d

proc passingPlacesByDistance*(world: World, viewer: int): seq[int] =
  ## Every aisle junction OTHER THAN the robot's own cell, nearest first, ties
  ## by lowest cell index -- the candidates `yield` backs out to. Excluding the
  ## robot's own cell is what makes `yield` an action rather than a no-op:
  ## standing still on the contested cell still blocks the robot behind you,
  ## because a self-edge is a length-1 cycle and everyone queued behind it
  ## stays.
  let me = world.robots[viewer].cell
  for cell in world.wh.passing:
    if cell != me:
      result.add(cell)
  for i in 1 ..< result.len:
    let cur = result[i]
    let curKey = world.wh.chebyshev(me, cur)
    var j = i - 1
    while j >= 0:
      let otherKey = world.wh.chebyshev(me, result[j])
      if otherKey > curKey or (otherKey == curKey and result[j] > cur):
        result[j + 1] = result[j]
        dec j
      else:
        break
    result[j + 1] = cur

proc nearestPassingPlace*(world: World, viewer: int): int =
  let places = passingPlacesByDistance(world, viewer)
  if places.len == 0: -1 else: places[0]
