## Cell-for-cell layout equality against a DIRECT transcription of upstream's
## own layout loop -- written here, separately, from `vendor/upstream/
## warehouse.py`, so `warehouse.nim`'s generator is checked against a second
## implementation rather than against itself.

import std/[algorithm, strutils, unittest]
import helpers

proc upstreamLayout(
  shelfColumns, shelfRows, columnHeight: int
): tuple[width, height: int, highway: seq[bool], goals: seq[(int, int)],
         shelves: seq[(int, int)]] =
  ## `_make_layout_from_params`, transcribed line for line:
  ##
  ##   grid_size = ((column_height + 1) * shelf_rows + 2,
  ##                (2 + 1) * shelf_columns + 1)
  ##   goals = [(w//2 - 1, h - 1), (w//2, h - 1)]
  ##   highway_func(x, y) = x % 3 == 0
  ##                     or y % (column_height + 1) == 0
  ##                     or y == h - 1
  ##                     or (y > h - (column_height + 3)
  ##                         and x in {w//2 - 1, w//2})
  ##   shelfs = [Shelf(x, y) for y, x in row-major indices if not highway]
  let
    height = (columnHeight + 1) * shelfRows + 2
    width = (2 + 1) * shelfColumns + 1
  result.width = width
  result.height = height
  result.highway = newSeq[bool](width * height)
  result.goals = @[(width div 2 - 1, height - 1), (width div 2, height - 1)]
  for x in 0 ..< width:
    for y in 0 ..< height:
      let
        onVertical = x mod 3 == 0
        onHorizontal = y mod (columnHeight + 1) == 0
        onDelivery = y == height - 1
        onQueue = (y > height - (columnHeight + 3)) and
          (x == width div 2 - 1 or x == width div 2)
      result.highway[y * width + x] =
        onVertical or onHorizontal or onDelivery or onQueue
  for y in 0 ..< height:
    for x in 0 ..< width:
      if not result.highway[y * width + x]:
        result.shelves.add((x, y))

suite "rware layout":

  test "cell for cell against the transcription, five shapes":
    for (rows, cols) in [(1, 3), (2, 3), (2, 5), (3, 5), (1, 5)]:
      let
        want = upstreamLayout(cols, rows, 8)
        got = initWarehouse(cols, rows, 8)
      checkpoint("shelf_rows " & $rows & ", shelf_columns " & $cols)
      check got.width == want.width
      check got.height == want.height
      for cell in 0 ..< want.highway.len:
        check got.isHighway(cell) == want.highway[cell]
      check got.shelfCount() == want.shelves.len
      for id, (x, y) in want.shelves:
        ## shelf ids are assigned in SCAN ORDER: ascending y, then ascending x
        check got.slotCell[id] == got.cellIndex(x, y)
      for g in 0 ..< want.goals.len:
        check got.cellX(got.goals[g]) == want.goals[g][0]
        check got.cellY(got.goals[g]) == want.goals[g][1]

  test "the tiny shape is exactly 10x11 with 32 shelves":
    let wh = initWarehouse(3, 1, 8)
    check (wh.width, wh.height) == (10, 11)
    check wh.shelfCount() == 32
    check (wh.cellX(wh.goals[0]), wh.cellY(wh.goals[0])) == (4, 10)
    check (wh.cellX(wh.goals[1]), wh.cellY(wh.goals[1])) == (5, 10)
    ## two 2x8 blocks at x in {1,2,7,8}, y in 1..8 -- the queue lane removes the
    ## whole middle block, exactly as upstream's docstring says it should
    var columns: seq[int]
    for cell in wh.slotCell:
      let x = wh.cellX(cell)
      if x notin columns:
        columns.add(x)
      check wh.cellY(cell) in 1 .. 8
    columns.sort()
    check columns == @[1, 2, 7, 8]

  test "the wide shape is exactly 16x11 with 64 shelves":
    let wh = initWarehouse(5, 1, 8)
    check (wh.width, wh.height) == (16, 11)
    check wh.shelfCount() == 64
    check (wh.cellX(wh.goals[0]), wh.cellY(wh.goals[0])) == (7, 10)
    check (wh.cellX(wh.goals[1]), wh.cellY(wh.goals[1])) == (8, 10)
    var columns: seq[int]
    for cell in wh.slotCell:
      let x = wh.cellX(cell)
      if x notin columns:
        columns.add(x)
    columns.sort()
    check columns == @[1, 2, 4, 5, 10, 11, 13, 14]

  test "every vertical aisle is exactly one cell wide":
    ## Two adjacent aisle columns anywhere except the workstation queue lane
    ## would make the corridors two robots wide and the whole game trivial. The
    ## lane itself is deliberately two wide -- upstream's own queue -- so the
    ## two columns beside it are excluded.
    for cols in [3, 5]:
      let wh = initWarehouse(cols, 1, 8)
      let
        laneLeft = wh.width div 2 - 1
        laneRight = wh.width div 2
      for y in 1 ..< wh.height - 2:
        for x in 0 ..< wh.width - 1:
          if x in [laneLeft, laneRight] or x + 1 in [laneLeft, laneRight]:
            continue
          if wh.isHighway(wh.cellIndex(x, y)) and
              wh.isHighway(wh.cellIndex(x + 1, y)):
            checkpoint("cols " & $cols & ": aisle is two wide at (" & $x &
              "," & $y & ")")
            fail()

  test "shelf ids round-trip through their labels":
    let wh = initWarehouse(5, 1, 8)
    for id in 0 ..< wh.shelfCount():
      let label = shelfLabel(id)
      check label.len >= 3
      check label[0] == 'S'
      check parseShelfLabel(label, wh.shelfCount()) == id
      check parseShelfLabel(label.toLowerAscii(), wh.shelfCount()) == id
    check parseShelfLabel("S00", wh.shelfCount()) == -1
    check parseShelfLabel("S65", wh.shelfCount()) == -1
    check parseShelfLabel("", wh.shelfCount()) == -1
    check parseShelfLabel("W1", wh.shelfCount()) == -1
    ## capped at MaxShelfIdRunes BEFORE matching, so an oversized id can never
    ## be a match
    check parseShelfLabel("S0001", wh.shelfCount()) == -1
    check parseStationLabel("W1") == 0
    check parseStationLabel("w2") == 1
    check parseStationLabel("W3") == -1

  test "the ASCII floor plan agrees with the mask":
    let wh = initWarehouse(3, 1, 8)
    let rows = wh.asciiMap().splitLines()
    check rows.len == wh.height
    for y in 0 ..< wh.height:
      check rows[y].len == wh.width
      for x in 0 ..< wh.width:
        let cell = wh.cellIndex(x, y)
        let want =
          if cell == wh.goals[0] or cell == wh.goals[1]: 'W'
          elif wh.isHighway(cell): '.'
          else: '#'
        check rows[y][x] == want

  test "spawns are distinct cells and legal facings":
    for seed in [1, 42, 999, 123456]:
      let world = initWorld(3, 1, 8, 4, 4, 3, seed)
      var seen: seq[int]
      for robot in world.robots:
        check robot.cell notin seen
        seen.add(robot.cell)
        check robot.cell >= 0
        check robot.cell < world.wh.width * world.wh.height
        check robot.facing in [DirUp, DirDown, DirLeft, DirRight]
        check robot.carrying == -1
      check world.requestQueue.len == 4
      var requested: seq[int]
      for id in world.requestQueue:
        check id notin requested
        requested.add(id)
        check world.requested[id]
      ## every non-highway cell holds a standing shelf at reset
      for cell in world.wh.slotCell:
        check world.standingShelfAt(cell) == world.wh.storageOf[cell]

  test "passing places are junctions clear of the workstation queue lane":
    for cols in [3, 5]:
      let wh = initWarehouse(cols, 1, 8)
      check wh.passing.len > 0
      let
        laneLeft = wh.width div 2 - 1
        laneRight = wh.width div 2
      for cell in wh.passing:
        check wh.isHighway(cell)
        check wh.cellX(cell) != laneLeft
        check wh.cellX(cell) != laneRight
        var free = 0
        for direction in NeighbourOrder:
          let next = wh.neighbourCell(cell, direction)
          if next >= 0 and wh.isHighway(next):
            inc free
        check free >= 3
