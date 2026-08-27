## The baseline sweep's pick, and the cooperative evidence behind it.

import std/[json, unittest]
import helpers
import "../tools/tune_baselines"

suite "rware baseline tuning":

  test "the shipped defaults are the swept pick":
    let tuning = parseJson(readRepoFile("tools/ci/baseline_tuning.json"))
    check DefaultBaselineParams.yieldAfter == tuning["yieldAfter"].getInt()
    check DefaultBaselineParams.penalty == tuning["penalty"].getInt()
    check DefaultBaselineParams.stowClearance ==
      tuning["stowClearance"].getInt()

  test "the sweep still ranks the shipped pick in the top half":
    ## The same sweep the tool runs, over a shorter horizon, so a change to the
    ## pilot that makes another parameter set strictly better shows up here
    ## rather than in a ladder round. `ci.yml` re-runs the tool itself with
    ## `--check`, at the horizon the pick came from.
    let ranking = sweepBaselines(shelfColumns = 3, maxTicks = 120)
    check ranking.len == 27
    checkpoint("best " & $ranking[0].params & " score " & $ranking[0].score)
    var rank = -1
    for i, entry in ranking:
      if entry.params == DefaultBaselineParams:
        rank = i
    check rank >= 0
    check rank <= ranking.len div 2

  test "the fleet delivers, on both floors, with the fixture's seat mix":
    ## The measurement is COOPERATIVE: two courteous and two shuttle robots,
    ## exactly the certification fixture's mix, and the number is the fleet's
    ## throughput. A pilot change that jammed the aisles would show up as a
    ## zero here long before a ladder round noticed.
    for cols in [3, 5]:
      var config = testConfig(shelfColumns = cols, maxTicks = 300,
        requestQueue = (if cols == 3: 4 else: 2))
      let run = runScriptedEpisode(config)
      checkpoint("shelfColumns " & $cols & ": delivered " &
        $run.sim.teamDelivered() & ", jams " & $run.sim.jamState.count)
      check run.sim.teamDelivered() > 0
      ## every seat contributes: a fleet where one robot does all the work is
      ## a fleet whose aisles are jammed for the other three
      var working = 0
      for seat in 0 ..< SeatCount:
        if run.sim.deliveredBy(seat) > 0:
          inc working
      check working >= 2

  test "the fallback is a real fleet member, not a walkover":
    ## `courteous` is the server-side fallback, so a champion that loses a turn
    ## to a timeout must not thereby sink the fleet. Four courteous robots
    ## deliver at least as much as four shuttle robots, which have no jam
    ## handling at all.
    var config = testConfig(maxTicks = 300)
    let courteous = runScriptedEpisode(config, "",
      [blCourteous, blCourteous, blCourteous, blCourteous])
    let shuttle = runScriptedEpisode(config, "",
      [blShuttle, blShuttle, blShuttle, blShuttle])
    checkpoint("courteous " & $courteous.sim.teamDelivered() &
      " v shuttle " & $shuttle.sim.teamDelivered())
    check courteous.sim.teamDelivered() > 0
    check courteous.sim.teamDelivered() >= shuttle.sim.teamDelivered()
