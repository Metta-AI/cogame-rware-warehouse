## The baseline tuning sweep. Not a guess: the three `courteous` tunables come
## from a head-to-head grid, and `tools/ci/baseline_tuning.json` records the
## pick that `tests/test_rware_tuning.nim` then pins.
##
##   nim c -r --path:src tools/tune_baselines.nim            # print the sweep
##   nim c -r --path:src tools/tune_baselines.nim --check     # verify the pick
##
## Both baselines are scripted and the sim is deterministic, so one episode per
## cell is the whole measurement -- there is nothing to average over. The game
## is COOPERATIVE, so the metric is the FLEET's throughput, not a duel: a
## candidate is ranked by the shelves a mixed fleet of two `courteous` and two
## `shuttle` robots delivers with those tunables, summed over several seeds so
## one lucky spawn cannot pick the parameters.

import std/[json, os, strformat, strutils]
import ../src/rware/[sim, baselines, decide, episode]

export sim, baselines

type
  SweepEntry* = object
    params*: BaselineParams
    score*: int

proc paramsConfig(seed, shelfColumns, maxTicks: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.shelfColumns = shelfColumns
  result.maxTicks = maxTicks
  result.turnTicks = 20
  result.turnSpacingMs = 0
  result.gameOverTicks = 2
  result.lobbyJoinTimeoutTicks = 1
  result.players = @[
    PlayerConfig(name: "Alpha"), PlayerConfig(name: "Bravo"),
    PlayerConfig(name: "Charlie"), PlayerConfig(name: "Delta")]
  result.clampConfig()

proc runFleet(
  params: BaselineParams, seed, shelfColumns, maxTicks: int
): int =
  ## One cooperative episode with the certification fixture's seat mix --
  ## courteous, shuttle, courteous, shuttle -- and these tunables on the
  ## courteous seats. The measurement is the fleet's delivered count.
  var config = paramsConfig(seed, shelfColumns, maxTicks)
  var engine = initDecisionEngine(config)
  engine.seats[0].baseline = blCourteous
  engine.seats[1].baseline = blShuttle
  engine.seats[2].baseline = blCourteous
  engine.seats[3].baseline = blShuttle
  engine.baselineParams = params
  let run = runHeadlessEpisode(config, engine, "")
  run.sim.teamDelivered()

proc headToHead*(
  params: BaselineParams, seed = 42, shelfColumns = 3, maxTicks = 200
): int =
  runFleet(params, seed, shelfColumns, maxTicks)

const SweepSeeds* = [42, 7, 1234]

proc sweepBaselines*(shelfColumns = 3, maxTicks = 200): seq[SweepEntry] =
  ## The grid: yield threshold x contention penalty x stow clearance, ranked by
  ## the fleet's total throughput over `SweepSeeds`.
  for yieldAfter in [4, 6, 9]:
    for penalty in [0, 4, 8]:
      for clearance in [0, 2, 4]:
        let params = BaselineParams(
          yieldAfter: yieldAfter, penalty: penalty, stowClearance: clearance)
        var total = 0
        for seed in SweepSeeds:
          total += runFleet(params, seed, shelfColumns, maxTicks)
        result.add(SweepEntry(params: params, score: total))
  # insertion sort, descending: the grid is 27 entries and a dependency-free
  # sort keeps the ordering identical on every platform
  for i in 1 ..< result.len:
    let cur = result[i]
    var j = i - 1
    while j >= 0 and result[j].score < cur.score:
      result[j + 1] = result[j]
      dec j
    result[j + 1] = cur

when isMainModule:
  let check = "--check" in commandLineParams()
  let ranking = sweepBaselines()
  echo "yieldAfter penalty stowClearance  shelves delivered (3 seeds)"
  for entry in ranking:
    echo &"{entry.params.yieldAfter:>10} {entry.params.penalty:>7} " &
      &"{entry.params.stowClearance:>13}  {entry.score:>6}"
  let recorded = parseJson(readFile(
    currentSourcePath().parentDir().parentDir() /
    "tools/ci/baseline_tuning.json"))
  let pick = BaselineParams(
    yieldAfter: recorded["yieldAfter"].getInt(),
    penalty: recorded["penalty"].getInt(),
    stowClearance: recorded["stowClearance"].getInt())
  echo "shipped pick: ", pick
  if pick != DefaultBaselineParams:
    quit("tools/ci/baseline_tuning.json disagrees with DefaultBaselineParams", 1)
  if check:
    var rank = -1
    for i, entry in ranking:
      if entry.params == pick:
        rank = i
    if rank < 0:
      quit("the shipped pick is not in the swept grid", 1)
    if rank > ranking.len div 2:
      quit("the shipped pick ranks " & $rank & " of " & $ranking.len &
        "; re-sweep and update tools/ci/baseline_tuning.json", 1)
    echo "shipped pick ranks ", rank, " of ", ranking.len, ": ok"
