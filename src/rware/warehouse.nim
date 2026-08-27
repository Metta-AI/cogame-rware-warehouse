## The static world: the transcription of upstream's `_make_layout_from_params`
## (grid size, `highway_func`, the two goal cells), the shelf placement over
## every non-highway cell, shelf-id assignment in scan order, cell<->index
## helpers, the passing-place table `yield` steers to, and BFS.
##
## PURE INTEGER. No pixie, no pixel queries, no floating point -- the native
## and wasm builds must agree bit for bit, and `tests/test_rware_sim.nim`'s
## no-float grep enforces it mechanically.

import std/strutils
import upstream, sim_types

type
  Warehouse* = object
    width*, height*: int
    shelfColumns*, shelfRows*, columnHeight*: int
    highway*: seq[bool]        ## cell index -> is this an aisle cell?
    storageOf*: seq[int]       ## cell index -> storage slot index, or -1
    slotCell*: seq[int]        ## storage slot index -> cell index
    goals*: array[GoalCount, int]  ## W1, W2 as cell indices
    passing*: seq[int]         ## aisle junctions, ascending cell index

proc cellIndex*(wh: Warehouse, x, y: int): int {.inline.} =
  y * wh.width + x

proc cellX*(wh: Warehouse, cell: int): int {.inline.} =
  cell mod wh.width

proc cellY*(wh: Warehouse, cell: int): int {.inline.} =
  cell div wh.width

proc onBoard*(wh: Warehouse, x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < wh.width and y < wh.height

proc isHighwayXY*(width, height, columnHeight, x, y: int): bool =
  ## Upstream's `highway_func`, clause for clause:
  ##   is_on_vertical_highway   = x % 3 == 0
  ##   is_on_horizontal_highway = y % (column_height + 1) == 0
  ##   is_on_delivery_row       = y == height - 1
  ##   is_on_queue              = y > height - (column_height + 3)
  ##                              and x in {width//2 - 1, width//2}
  let
    vertical = x mod HighwayVerticalModulus == 0
    horizontal = y mod (columnHeight + 1) == 0
    delivery = y == height - 1
    queue = (y > height - (columnHeight + QueueLaneOffset)) and
      (x == width div 2 - 1 or x == width div 2)
  vertical or horizontal or delivery or queue

proc isHighway*(wh: Warehouse, cell: int): bool {.inline.} =
  wh.highway[cell]

proc isStorage*(wh: Warehouse, cell: int): bool {.inline.} =
  not wh.highway[cell]

proc initWarehouse*(shelfColumns, shelfRows, columnHeight: int): Warehouse =
  ## `_make_layout_from_params`, transcribed. Shelf ids are assigned in SCAN
  ## ORDER -- ascending y, then ascending x -- which is exactly the order
  ## upstream builds `self.shelfs` in (`np.indices(...).reshape(-1)` is
  ## row-major).
  result.shelfColumns = shelfColumns
  result.shelfRows = shelfRows
  result.columnHeight = columnHeight
  result.height = gridHeight(columnHeight, shelfRows)
  result.width = gridWidth(shelfColumns)
  let cells = result.width * result.height
  result.highway = newSeq[bool](cells)
  result.storageOf = newSeq[int](cells)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      let cell = y * result.width + x
      result.highway[cell] =
        isHighwayXY(result.width, result.height, columnHeight, x, y)
      result.storageOf[cell] = -1
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      let cell = y * result.width + x
      if not result.highway[cell]:
        result.storageOf[cell] = result.slotCell.len
        result.slotCell.add(cell)
  result.goals[0] =
    (result.height - 1) * result.width + (result.width div 2 - 1)
  result.goals[1] =
    (result.height - 1) * result.width + (result.width div 2)
  # Passing places: an aisle cell with at least three orthogonal neighbours
  # that are themselves on the board and on an aisle -- a junction a robot can
  # back into and still leave the lane open -- and OUTSIDE the workstation
  # queue lane, which is where every delivery jams and is therefore the one
  # place backing off does not help.
  let
    laneLeft = result.width div 2 - 1
    laneRight = result.width div 2
  for cell in 0 ..< cells:
    if not result.highway[cell]:
      continue
    let
      x = cell mod result.width
      y = cell div result.width
    if x == laneLeft or x == laneRight:
      continue
    var free = 0
    if x > 0 and result.highway[cell - 1]: inc free
    if x < result.width - 1 and result.highway[cell + 1]: inc free
    if y > 0 and result.highway[cell - result.width]: inc free
    if y < result.height - 1 and result.highway[cell + result.width]: inc free
    if free >= 3:
      result.passing.add(cell)

proc shelfCount*(wh: Warehouse): int {.inline.} =
  wh.slotCell.len

proc shelfLabel*(id: int): string =
  ## `S01` .. `S64`. Two digits always, so the ids sort as text and the label
  ## fits `MaxShelfIdRunes`.
  "S" & align($(id + 1), 2, '0')

proc parseShelfLabel*(text: string, count: int): int =
  ## The shelf index a label names, or -1. Case-insensitive, capped at
  ## `MaxShelfIdRunes` BEFORE matching so an oversized id can never match.
  let key = text.strip().truncateRunes(MaxShelfIdRunes).toUpperAscii()
  if key.len < 2 or key[0] != 'S':
    return -1
  var value = 0
  for i in 1 ..< key.len:
    if key[i] notin {'0' .. '9'}:
      return -1
    value = value * 10 + (int(key[i]) - int('0'))
  if value < 1 or value > count:
    return -1
  value - 1

proc stationLabel*(index: int): string =
  if index == 0: "W1" else: "W2"

proc parseStationLabel*(text: string): int =
  ## 0 for W1, 1 for W2, -1 for anything else.
  let key = text.strip().truncateRunes(MaxStationRunes).toUpperAscii()
  if key == "W1": 0
  elif key == "W2": 1
  else: -1

proc stepCell*(wh: Warehouse, cell, facing: int): int =
  ## The cell one step ahead, CLAMPED to the board exactly the way upstream's
  ## `req_location` clamps it -- a wall bump therefore returns the robot's own
  ## cell and becomes a self-edge in the move graph.
  let
    x = cell mod wh.width
    y = cell div wh.width
  case facing
  of DirUp: max(0, y - 1) * wh.width + x
  of DirDown: min(wh.height - 1, y + 1) * wh.width + x
  of DirLeft: y * wh.width + max(0, x - 1)
  else: y * wh.width + min(wh.width - 1, x + 1)

proc turn*(facing, action: int): int =
  ## `req_direction`: RIGHT steps +1 through [UP, RIGHT, DOWN, LEFT], LEFT -1.
  var at = 0
  for i in 0 ..< WrapList.len:
    if WrapList[i] == facing:
      at = i
  if action == ActionRight:
    WrapList[(at + 1) mod WrapList.len]
  elif action == ActionLeft:
    WrapList[(at + WrapList.len - 1) mod WrapList.len]
  else:
    facing

proc facingToward*(fromCell, toCell, width: int): int =
  ## The facing that steps from `fromCell` onto the orthogonally adjacent
  ## `toCell`. Only called with adjacent cells.
  if toCell == fromCell - width: DirUp
  elif toCell == fromCell + width: DirDown
  elif toCell == fromCell - 1: DirLeft
  else: DirRight

proc facingName*(facing: int): string =
  case facing
  of DirUp: "up"
  of DirDown: "down"
  of DirLeft: "left"
  else: "right"

const NeighbourOrder* = [DirUp, DirRight, DirDown, DirLeft]
  ## Neighbours are expanded up, right, down, left -- a FIXED order, so the
  ## BFS path is unique and the native and wasm builds agree.

proc neighbourCell*(wh: Warehouse, cell, direction: int): int =
  ## The orthogonal neighbour, or -1 off the board. Unlike `stepCell` this does
  ## NOT clamp: the pathfinder needs to know the board ended.
  let
    x = cell mod wh.width
    y = cell div wh.width
  case direction
  of DirUp: (if y > 0: cell - wh.width else: -1)
  of DirDown: (if y < wh.height - 1: cell + wh.width else: -1)
  of DirLeft: (if x > 0: cell - 1 else: -1)
  else: (if x < wh.width - 1: cell + 1 else: -1)

proc bfsFirstStep*(
  wh: Warehouse, start, goal: int, passable: openArray[bool]
): int =
  ## The first cell of the shortest 4-connected path from `start` to `goal`
  ## over the cells `passable` admits, or -1 when no route exists. `start` and
  ## `goal` are always admissible whatever `passable` says: a robot standing on
  ## a cell can leave it, and the order's destination is the point.
  ##
  ## Neighbours are expanded in `NeighbourOrder`, so the path is unique.
  if start == goal:
    return start
  let cells = wh.width * wh.height
  var
    prev = newSeq[int](cells)
    seen = newSeq[bool](cells)
    queue = newSeq[int](cells)
    head = 0
    tail = 0
  for i in 0 ..< cells:
    prev[i] = -1
  seen[start] = true
  queue[tail] = start
  inc tail
  while head < tail:
    let cell = queue[head]
    inc head
    for direction in NeighbourOrder:
      let next = wh.neighbourCell(cell, direction)
      if next < 0 or seen[next]:
        continue
      if next != goal and not passable[next]:
        continue
      seen[next] = true
      prev[next] = cell
      if next == goal:
        var step = goal
        while prev[step] != start:
          step = prev[step]
        return step
      queue[tail] = next
      inc tail
  -1

proc bfsDistance*(
  wh: Warehouse, start, goal: int, passable: openArray[bool]
): int =
  ## The shortest 4-connected distance in cells, or -1 when unreachable.
  if start == goal:
    return 0
  let cells = wh.width * wh.height
  var
    dist = newSeq[int](cells)
    queue = newSeq[int](cells)
    head = 0
    tail = 0
  for i in 0 ..< cells:
    dist[i] = -1
  dist[start] = 0
  queue[tail] = start
  inc tail
  while head < tail:
    let cell = queue[head]
    inc head
    for direction in NeighbourOrder:
      let next = wh.neighbourCell(cell, direction)
      if next < 0 or dist[next] >= 0:
        continue
      if next != goal and not passable[next]:
        continue
      dist[next] = dist[cell] + 1
      if next == goal:
        return dist[next]
      queue[tail] = next
      inc tail
  -1

proc asciiMap*(wh: Warehouse): string =
  ## The floor plan a driver is handed once, at registration: `#` a storage
  ## slot, `.` an aisle, `W` a workstation. Static for the whole episode.
  var lines: seq[string]
  for y in 0 ..< wh.height:
    var row = ""
    for x in 0 ..< wh.width:
      let cell = y * wh.width + x
      if cell == wh.goals[0] or cell == wh.goals[1]: row.add('W')
      elif wh.highway[cell]: row.add('.')
      else: row.add('#')
    lines.add(row)
  lines.join("\n")
