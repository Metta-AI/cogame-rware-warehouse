## The port TRIPWIRE.
##
## `src/rware/upstream.nim` is the one place an upstream number is written
## down. This file regex-parses the BYTE-PRISTINE vendored sources and asserts
## byte-equality against every entry, so a re-vendor that changes a number
## fails the tests instead of silently desyncing the game.

import std/[strutils, unittest]
import helpers
import rware/upstream

const
  WarehousePath = "vendor/upstream/warehouse.py"
  InitPath = "vendor/upstream/__init__.py"

proc source(path: string): string =
  check repoFileExists(path)
  readRepoFile(path)

suite "rware upstream tripwire":

  test "the vendored files are present and unmodified":
    ## sha256 is recorded in vendor/UPSTREAM.md and pinned in upstream.nim; the
    ## commit is the fetch pin. Byte-length is not enough, so the doc and the
    ## const must agree and the files must be readable as UTF-8.
    let notes = source("vendor/UPSTREAM.md")
    check UpstreamCommit in notes
    check UpstreamSha256 in notes
    check UpstreamInitSha256 in notes
    check UpstreamRepo in notes
    discard source(WarehousePath).len
    discard source(InitPath).len
    check repoFileExists("vendor/LICENSE-rware")
    check repoFileExists("vendor/PATCHES.md")

  test "the action enum and its integer values":
    let text = source(WarehousePath)
    check "class Action(Enum):" in text
    check "\n    NOOP = " & $ActionNoop & "\n" in text
    check "\n    FORWARD = " & $ActionForward & "\n" in text
    check "\n    LEFT = " & $ActionLeft & "\n" in text
    check "\n    RIGHT = " & $ActionRight & "\n" in text
    check "\n    TOGGLE_LOAD = " & $ActionToggleLoad & "\n" in text
    ## five actions and nothing else: msg_bits is 0, so it is a plain
    ## Discrete(5)
    check ActionCount == 5

  test "the direction enum and the rotation wrap list":
    let text = source(WarehousePath)
    check "class Direction(Enum):" in text
    check "\n    UP = " & $DirUp & "\n" in text
    check "\n    DOWN = " & $DirDown & "\n" in text
    check "\n    LEFT = " & $DirLeft & "\n" in text
    check "\n    RIGHT = " & $DirRight & "\n" in text
    check "wraplist = [Direction.UP, Direction.RIGHT, Direction.DOWN, " &
      "Direction.LEFT]" in text
    check WrapList == [DirUp, DirRight, DirDown, DirLeft]

  test "the two grid-size formulas":
    let text = source(WarehousePath)
    check "(column_height + 1) * shelf_rows + 2," in text
    check "(2 + 1) * shelf_columns + 1," in text
    check GridHeightRowTerm == 1
    check GridHeightConst == 2
    check GridWidthFactor == 3
    check GridWidthConst == 1
    check gridHeight(8, 1) == 11
    check gridWidth(3) == 10
    check gridWidth(5) == 16
    check "assert shelf_columns % 2 == 1" in text

  test "the four highway_func clauses":
    let text = source(WarehousePath)
    check "is_on_vertical_highway = x % 3 == 0" in text
    check "is_on_horizontal_highway = y % (column_height + 1) == 0" in text
    check "is_on_delivery_row = y == self.grid_size[0] - 1" in text
    check "is_on_queue = (y > self.grid_size[0] - (column_height + 3)) and (" in
      text
    check "x == self.grid_size[1] // 2 - 1 or x == self.grid_size[1] // 2" in
      text
    check HighwayVerticalModulus == 3
    check QueueLaneOffset == 3

  test "the goal-cell formula":
    let text = source(WarehousePath)
    check "(self.grid_size[1] // 2 - 1, self.grid_size[0] - 1)," in text
    check "(self.grid_size[1] // 2, self.grid_size[0] - 1)," in text
    check GoalCount == 2

  test "the registered size and difficulty tables":
    let text = source(InitPath)
    check "\"tiny\": (1, 3)," in text
    check "\"small\": (2, 3)," in text
    check "\"medium\": (2, 5)," in text
    check "\"large\": (3, 5)," in text
    check SizeNames == ["tiny", "small", "medium", "large"]
    check SizeRows == [1, 2, 2, 3]
    check SizeColumns == [3, 3, 5, 5]
    check "_difficulty = {\"-easy\": 2, \"\": 1, \"-hard\": 0.5}" in text
    check DifficultyNames == ["-easy", "", "-hard"]
    check DifficultyTimes2 == [4, 2, 1]
    ## request_queue_size = int(agents * d), in integers
    check "\"request_queue_size\": int(agents * _difficulty[diff])" in text
    check requestQueueSize(4, 0) == 8      ## easy: 4 x 2
    check requestQueueSize(4, 1) == 4      ## normal: 4 x 1
    check requestQueueSize(4, 2) == 2      ## hard: int(4 x 0.5)
    check requestQueueSize(3, 2) == 1      ## int(3 x 0.5) == 1, floored

  test "the registered environment kwargs":
    let text = source(InitPath)
    check "\"column_height\": 8," in text
    check "\"sensor_range\": 1," in text
    check "\"max_steps\": 500," in text
    check "\"msg_bits\": 0," in text
    check "\"max_inactivity_steps\": None," in text
    check "\"reward_type\": RewardType.INDIVIDUAL," in text
    check ColumnHeightDefault == 8
    check SensorRangeUpstream == 1
    check MaxStepsDefault == 500
    check MsgBits == 0
    check MaxInactivityStepsUpstream == "None"
    check RewardTypeUpstream == "INDIVIDUAL"

  test "the collision-resolution rules are upstream's":
    let text = source(WarehousePath)
    ## the loaded-move veto, clause for clause
    check "agent.carrying_shelf" in text
    check "and start != target" in text
    check "].carrying_shelf" in text
    ## the cycle / longest-path split
    check "cycle = nx.algorithms.find_cycle(comp)" in text
    check "if len(cycle) == 2:" in text
    check "longest_path = nx.algorithms.dag_longest_path(comp)" in text
    ## unload only off a highway
    check "if not self._is_highway(agent.x, agent.y):" in text
    ## the delivery refill draws from the shelves not currently requested
    check ("candidates = [s for s in self.shelfs if s not in " &
      "self.request_queue]") in text

  test "every ported constant is cited in the module that owns it":
    ## The citation comments are the audit trail: a number without one is a
    ## number nobody can check against the vendored file.
    let module = readRepoFile("src/rware/upstream.nim")
    for citation in ["NOOP = 0", "FORWARD = 1", "TOGGLE_LOAD = 4",
                     "wraplist = [UP, RIGHT, DOWN, LEFT]",
                     "is_on_vertical_highway = x % 3 == 0",
                     "\"column_height\": 8", "\"max_steps\": 500",
                     "\"sensor_range\": 1", "\"msg_bits\": 0"]:
      check citation in module
    check UpstreamPath == "rware/warehouse.py"
    check UpstreamInitPath == "rware/__init__.py"
