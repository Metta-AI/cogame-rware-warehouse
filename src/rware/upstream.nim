## Every constant ported from `semitable/robotic-warehouse`, each beside the
## line of `vendor/upstream/warehouse.py` (or `__init__.py`) it was read from.
##
## This module is the ONE place an upstream number is written down, and
## `tests/test_rware_upstream.nim` regex-parses the vendored files and asserts
## byte-equality against every entry here. A re-vendor that changes a number
## therefore FAILS THE TESTS instead of silently desyncing the game.
##
## PURE INTEGER. RWARE's rules are already integral -- cells, ids, counts and
## a +1 reward -- so nothing here needs a scaling trick: the only non-integer
## upstream value is the difficulty multiplier, and `request_queue_size` is
## `int(n_agents * d)`, an integer by construction.

const
  UpstreamRepo* = "semitable/robotic-warehouse"
  UpstreamPath* = "rware/warehouse.py"
  UpstreamInitPath* = "rware/__init__.py"
  UpstreamCommit* = "96fbc64e3eae5fee915e0d390f864fa06ddccd47"
  UpstreamSha256* =
    "cc1be89dd654cde7928d6f0a813ebf36f070764adeb137fc1b74065f9344d12a"
  UpstreamInitSha256* =
    "a5aa8b89cf8bf06fd644d9514a6b7af66132df50b6867601b947af608da70352"

  # --- the action space (warehouse.py, class Action) -------------------------
  ActionNoop* = 0            ## NOOP = 0
  ActionForward* = 1         ## FORWARD = 1
  ActionLeft* = 2            ## LEFT = 2
  ActionRight* = 3           ## RIGHT = 3
  ActionToggleLoad* = 4      ## TOGGLE_LOAD = 4
  ActionCount* = 5           ## msg_bits = 0, so the action is Discrete(5)

  # --- directions (warehouse.py, class Direction) ----------------------------
  DirUp* = 0                 ## UP = 0
  DirDown* = 1               ## DOWN = 1
  DirLeft* = 2               ## LEFT = 2
  DirRight* = 3              ## RIGHT = 3
  WrapList*: array[4, int] = [DirUp, DirRight, DirDown, DirLeft]
    ## `req_direction`: wraplist = [UP, RIGHT, DOWN, LEFT]; RIGHT steps +1,
    ## LEFT steps -1, both modulo 4.

  # --- layout (warehouse.py, _make_layout_from_params) -----------------------
  GridHeightRowTerm* = 1
    ## height = (column_height + GridHeightRowTerm) * shelf_rows + 2
  GridHeightConst* = 2
  GridWidthFactor* = 3
    ## width = (2 + 1) * shelf_columns + 1
  GridWidthConst* = 1
  HighwayVerticalModulus* = 3
    ## is_on_vertical_highway = x % 3 == 0
  QueueLaneOffset* = 3
    ## is_on_queue = y > height - (column_height + 3) and x in {w//2-1, w//2}
  GoalCount* = 2
    ## goals = [(w//2 - 1, h - 1), (w//2, h - 1)]

  # --- registered environments (__init__.py) ---------------------------------
  ColumnHeightDefault* = 8   ## "column_height": 8
  SensorRangeUpstream* = 1   ## "sensor_range": 1
  MaxStepsDefault* = 500     ## "max_steps": 500
  MsgBits* = 0               ## "msg_bits": 0
  MaxInactivityStepsUpstream* = "None"   ## "max_inactivity_steps": None
  RewardTypeUpstream* = "INDIVIDUAL"     ## "reward_type": RewardType.INDIVIDUAL

  SizeNames*: array[4, string] = ["tiny", "small", "medium", "large"]
  SizeRows*: array[4, int] = [1, 2, 2, 3]
  SizeColumns*: array[4, int] = [3, 3, 5, 5]
    ## _sizes = {"tiny": (1, 3), "small": (2, 3), "medium": (2, 5),
    ##           "large": (3, 5)}

  DifficultyNames*: array[3, string] = ["-easy", "", "-hard"]
  DifficultyTimes2*: array[3, int] = [4, 2, 1]
    ## _difficulty = {"-easy": 2, "": 1, "-hard": 0.5}, doubled so the table
    ## is integral. `request_queue_size = int(n_agents * d)` is then
    ## `n_agents * DifficultyTimes2[k] div 2`.

proc requestQueueSize*(agents, difficultyIndex: int): int =
  ## `request_queue_size = int(n_agents * d)`, in integers.
  (agents * DifficultyTimes2[difficultyIndex]) div 2

proc gridHeight*(columnHeight, shelfRows: int): int =
  ## `(column_height + 1) * shelf_rows + 2`
  (columnHeight + GridHeightRowTerm) * shelfRows + GridHeightConst

proc gridWidth*(shelfColumns: int): int =
  ## `(2 + 1) * shelf_columns + 1`
  GridWidthFactor * shelfColumns + GridWidthConst
