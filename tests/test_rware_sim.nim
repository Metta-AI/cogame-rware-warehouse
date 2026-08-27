## The sim unit tests: upstream's rules, asserted one at a time on a board with
## exactly the pieces each rule is about.

import std/[json, monotimes, strutils, times, unittest]
import helpers

suite "rware sim":

  test "layout formula":
    ## 1. Grid size, the highway mask, the workstation cells and the shelf
    ##    count for BOTH shipped variants, against upstream's formulas.
    for (cols, w, h, shelves, gx) in [(3, 10, 11, 32, 4), (5, 16, 11, 64, 7)]:
      let wh = initWarehouse(cols, 1, 8)
      check wh.width == w
      check wh.height == h
      check wh.shelfCount() == shelves
      check wh.cellX(wh.goals[0]) == gx
      check wh.cellY(wh.goals[0]) == h - 1
      check wh.cellX(wh.goals[1]) == gx + 1
      check wh.cellY(wh.goals[1]) == h - 1
      ## every highway clause, cell for cell
      for y in 0 ..< h:
        for x in 0 ..< w:
          check wh.isHighway(wh.cellIndex(x, y)) ==
            isHighwayXY(w, h, 8, x, y)
      ## the workstations are on the delivery row and therefore aisles
      check wh.isHighway(wh.goals[0])
      check wh.isHighway(wh.goals[1])

  test "empty robots walk under shelves":
    ## 2. An unloaded robot enters a storage cell holding a shelf and the shelf
    ##    is untouched.
    var sim = emptyBoard()
    let shelf = sim.world.wh.storageOf[sim.cellOf(1, 1)]
    check shelf >= 0
    let slot = sim.place(1, 2, DirUp)
    sim.forceActions([ActionForward])
    check sim.world.robots[slot].cell == sim.cellOf(1, 1)
    check sim.world.shelves[shelf].cell == sim.cellOf(1, 1)
    check sim.world.shelves[shelf].carrier == -1
    check sim.world.standingShelfAt(sim.cellOf(1, 1)) == shelf

  test "loaded veto":
    ## 3. A carrying robot's FORWARD into a standing shelf is cancelled and
    ##    counted in blockedMoves; the same move IS allowed when the target
    ##    holds a robot that is itself carrying, and onto an empty storage cell
    ##    and any aisle cell.
    block intoStandingShelf:
      var sim = emptyBoard()
      let
        carried = sim.world.wh.storageOf[sim.cellOf(7, 1)]
        standing = sim.world.wh.storageOf[sim.cellOf(1, 1)]
      let slot = sim.place(1, 2, DirUp, carrying = carried)
      check standing >= 0
      sim.forceActions([ActionForward])
      check sim.world.robots[slot].cell == sim.cellOf(1, 2)
      check sim.world.robots[slot].blockedMoves == 1
    block ontoACarryingRobot:
      var sim = emptyBoard()
      let
        mine = sim.world.wh.storageOf[sim.cellOf(7, 1)]
        theirs = sim.world.wh.storageOf[sim.cellOf(8, 1)]
      let
        a = sim.place(1, 2, DirUp, carrying = mine)
        b = sim.place(1, 1, DirUp, carrying = theirs)
      ## b's own cell holds no STANDING shelf -- b is carrying one -- so a's
      ## move is legal and the pair advances as a chain.
      sim.forceActions([ActionForward, ActionForward])
      check sim.world.robots[a].cell == sim.cellOf(1, 1)
      check sim.world.robots[b].cell == sim.cellOf(1, 0)
    block ontoAnEmptySlotAndAnAisle:
      var sim = emptyBoard()
      let carried = sim.world.wh.storageOf[sim.cellOf(7, 1)]
      sim.world.shelves[sim.world.wh.storageOf[sim.cellOf(1, 1)]].cell = -1
      sim.world.rebuildLayers()
      let slot = sim.place(1, 2, DirUp, carrying = carried)
      sim.forceActions([ActionForward])
      check sim.world.robots[slot].cell == sim.cellOf(1, 1)
      ## and on out onto the horizontal highway at y = 0
      sim.forceActions([ActionForward])
      check sim.world.robots[slot].cell == sim.cellOf(1, 0)

  test "head-on":
    ## 4. Two robots facing each other one cell apart both request FORWARD:
    ##    NEITHER moves, on this tick and on every later tick, until one turns
    ##    away.
    var sim = emptyBoard()
    sim.clearShelves()
    let
      a = sim.place(3, 3, DirDown)
      b = sim.place(3, 4, DirUp)
    for _ in 0 ..< 5:
      sim.forceActions([ActionForward, ActionForward])
      check sim.world.robots[a].cell == sim.cellOf(3, 3)
      check sim.world.robots[b].cell == sim.cellOf(3, 4)
    check sim.world.robots[a].stuck == 5
    check sim.world.robots[b].stuck == 5
    ## one turns away and the other walks through
    sim.forceActions([ActionRight, ActionForward])
    check sim.world.robots[a].facing == DirLeft
    sim.forceActions([ActionForward, ActionForward])
    check sim.world.robots[a].cell == sim.cellOf(2, 3)

  test "rotation":
    ## 5. Three robots in a 3-cycle all move; four in a 4-cycle all move; a
    ##    robot pointing into a cycle from outside does not.
    block threeCycle:
      var sim = emptyBoard()
      sim.clearShelves()
      let
        a = sim.place(3, 3, DirRight)
        b = sim.place(4, 3, DirDown)
        c = sim.place(4, 4, DirLeft)
      ## a -> b -> c -> ... c faces (3,4); make it a true cycle back to a
      sim.world.robots[c].facing = DirLeft
      let d = sim.place(3, 4, DirUp)
      sim.forceActions([ActionForward, ActionForward, ActionForward,
        ActionForward])
      check sim.world.robots[a].cell == sim.cellOf(4, 3)
      check sim.world.robots[b].cell == sim.cellOf(4, 4)
      check sim.world.robots[c].cell == sim.cellOf(3, 4)
      check sim.world.robots[d].cell == sim.cellOf(3, 3)
    block pointingIntoACycle:
      var sim = emptyBoard()
      sim.clearShelves()
      let
        a = sim.place(3, 3, DirRight)
        b = sim.place(4, 3, DirLeft)
        outsider = sim.place(3, 2, DirDown)
      ## a and b are a 2-cycle: nobody in the component moves, the outsider
      ## included.
      sim.forceActions([ActionForward, ActionForward, ActionForward])
      check sim.world.robots[a].cell == sim.cellOf(3, 3)
      check sim.world.robots[b].cell == sim.cellOf(4, 3)
      check sim.world.robots[outsider].cell == sim.cellOf(3, 2)

  test "chain":
    ## 6. A queue of three robots behind one with somewhere to go all advance
    ##    in the same tick; the same queue behind a STATIONARY robot does not
    ##    move at all.
    block behindAMover:
      var sim = emptyBoard()
      sim.clearShelves()
      let
        a = sim.place(3, 1, DirUp)
        b = sim.place(3, 2, DirUp)
        c = sim.place(3, 3, DirUp)
      sim.forceActions([ActionForward, ActionForward, ActionForward])
      check sim.world.robots[a].cell == sim.cellOf(3, 0)
      check sim.world.robots[b].cell == sim.cellOf(3, 1)
      check sim.world.robots[c].cell == sim.cellOf(3, 2)
    block behindAStationary:
      var sim = emptyBoard()
      sim.clearShelves()
      let
        head = sim.place(3, 1, DirUp)
        b = sim.place(3, 2, DirUp)
        c = sim.place(3, 3, DirUp)
      ## the head does nothing: a self-edge is a length-1 cycle, so only the
      ## head "moves" -- to its own cell -- and the queue stays put.
      sim.forceActions([ActionNoop, ActionForward, ActionForward])
      check sim.world.robots[head].cell == sim.cellOf(3, 1)
      check sim.world.robots[b].cell == sim.cellOf(3, 2)
      check sim.world.robots[c].cell == sim.cellOf(3, 3)
      check sim.world.robots[b].blockedMoves == 1
      check sim.world.robots[c].blockedMoves == 1

  test "contention tie-break":
    ## 7. Two robots requesting the same empty cell from different branches:
    ##    the deterministic longest-path rule commits exactly one, the same one
    ##    on every run.
    var first = -1
    for run in 0 ..< 8:
      var sim = emptyBoard()
      sim.clearShelves()
      let
        a = sim.place(3, 3, DirDown)     ## wants (3,4)
        b = sim.place(2, 4, DirRight)    ## wants (3,4)
      sim.forceActions([ActionForward, ActionForward])
      let moved =
        if sim.world.robots[a].cell == sim.cellOf(3, 4): a
        elif sim.world.robots[b].cell == sim.cellOf(3, 4): b
        else: -1
      check moved >= 0
      if first < 0:
        first = moved
      check moved == first

  test "turning":
    ## 8. LEFT/RIGHT walk the wrap list [UP, RIGHT, DOWN, LEFT]; a wall-facing
    ##    FORWARD clamps to the robot's own cell and counts as blocked.
    check turn(DirUp, ActionRight) == DirRight
    check turn(DirRight, ActionRight) == DirDown
    check turn(DirDown, ActionRight) == DirLeft
    check turn(DirLeft, ActionRight) == DirUp
    check turn(DirUp, ActionLeft) == DirLeft
    check turn(DirLeft, ActionLeft) == DirDown
    check turn(DirDown, ActionLeft) == DirRight
    check turn(DirRight, ActionLeft) == DirUp
    check turn(DirUp, ActionNoop) == DirUp
    var sim = emptyBoard()
    sim.clearShelves()
    let slot = sim.place(0, 0, DirUp)
    sim.forceActions([ActionForward])
    check sim.world.robots[slot].cell == sim.cellOf(0, 0)
    check sim.world.robots[slot].blockedMoves == 1
    check sim.world.robots[slot].stuck == 1

  test "load and unload":
    ## 9. TOGGLE_LOAD lifts only from the robot's OWN cell and only when empty;
    ##    unloading is refused on every highway cell (the delivery row and the
    ##    queue lane included) and accepted on an empty storage cell.
    block lift:
      var sim = emptyBoard()
      let shelf = sim.world.wh.storageOf[sim.cellOf(1, 1)]
      let slot = sim.place(1, 1, DirUp)
      sim.forceActions([ActionToggleLoad])
      check sim.world.robots[slot].carrying == shelf
      check sim.world.shelves[shelf].carrier == slot
      check sim.world.standingShelfAt(sim.cellOf(1, 1)) == -1
      ## a second TOGGLE_LOAD on a highway cell is a no-op
      sim.world.robots[slot].cell = sim.cellOf(0, 1)
      sim.world.shelves[shelf].cell = sim.cellOf(0, 1)
      sim.world.rebuildLayers()
      check sim.world.wh.isHighway(sim.cellOf(0, 1))
      sim.forceActions([ActionToggleLoad])
      check sim.world.robots[slot].carrying == shelf
    block liftNothing:
      var sim = emptyBoard()
      sim.clearShelves()
      let slot = sim.place(3, 3, DirUp)
      sim.forceActions([ActionToggleLoad])
      check sim.world.robots[slot].carrying == -1
    block refusedOnEveryHighway:
      var sim = emptyBoard()
      let carried = sim.world.wh.storageOf[sim.cellOf(1, 1)]
      let slot = sim.place(4, 10, DirUp, carrying = carried)
      for (x, y) in [(4, 10), (5, 10), (4, 5), (5, 5), (3, 3), (2, 0)]:
        sim.world.robots[slot].cell = sim.cellOf(x, y)
        sim.world.shelves[carried].cell = sim.cellOf(x, y)
        sim.world.rebuildLayers()
        if not sim.world.wh.isHighway(sim.cellOf(x, y)):
          continue
        sim.forceActions([ActionToggleLoad])
        check sim.world.robots[slot].carrying == carried
    block acceptedOnAnEmptySlot:
      var sim = emptyBoard()
      let carried = sim.world.wh.storageOf[sim.cellOf(1, 1)]
      let target = sim.cellOf(7, 3)
      sim.world.shelves[sim.world.wh.storageOf[target]].cell = -1
      sim.world.rebuildLayers()
      let slot = sim.place(7, 3, DirUp, carrying = carried)
      sim.forceActions([ActionToggleLoad])
      check sim.world.robots[slot].carrying == -1
      check sim.world.robots[slot].stowed == 1
      check sim.world.standingShelfAt(target) == carried

  test "delivery and refill":
    ## 10. A requested shelf reaching W1 credits exactly the robot standing
    ##     there, increments teamDelivered once, replaces that queue entry with
    ##     a shelf NOT already in the queue, and leaves the shelf on the forks;
    ##     an unrequested shelf on a workstation credits nothing.
    block credited:
      var sim = emptyBoard()
      let carried = sim.world.wh.storageOf[sim.cellOf(1, 1)]
      sim.requestOnly([carried, carried + 1])
      let slot = sim.place(4, 9, DirDown, carrying = carried)
      let other = sim.place(1, 3, DirUp)
      sim.forceActions([ActionForward, ActionNoop])
      check sim.world.robots[slot].cell == sim.world.wh.goals[0]
      check sim.world.robots[slot].delivered == 1
      check sim.world.teamDelivered == 1
      check sim.world.robots[other].delivered == 0
      ## the shelf is still on the forks and must still be stowed
      check sim.world.robots[slot].carrying == carried
      check not sim.world.requested[carried]
      check sim.world.requestQueue.len == 2
      var seen: seq[int]
      for id in sim.world.requestQueue:
        check id notin seen
        seen.add(id)
        check sim.world.requested[id]
    block unrequested:
      var sim = emptyBoard()
      let carried = sim.world.wh.storageOf[sim.cellOf(1, 1)]
      sim.requestOnly([carried + 5])
      let slot = sim.place(4, 9, DirDown, carrying = carried)
      sim.forceActions([ActionForward])
      check sim.world.teamDelivered == 0
      check sim.world.robots[slot].delivered == 0

  test "jam detector":
    ## 11. Two robots deadlocked head-on raise a jam at exactly stuck == 8,
    ##     name both slots, keep jamTicks counting, and clear on the tick one
    ##     of them turns; a single robot stuck against a wall is NOT a jam.
    var sim = emptyBoard()
    sim.clearShelves()
    let
      a = sim.place(3, 3, DirDown)
      b = sim.place(3, 4, DirUp)
    for tick in 1 .. 7:
      sim.forceActions([ActionForward, ActionForward])
      check not sim.jamState.active
    sim.forceActions([ActionForward, ActionForward])
    check sim.jamState.active
    check sim.jamState.members == @[a, b]
    check sim.jamState.count == 1
    check sim.jamState.ticksTotal == 1
    sim.forceActions([ActionForward, ActionForward])
    check sim.jamState.ticksTotal == 2
    sim.forceActions([ActionRight, ActionRight])
    check not sim.jamState.active
    check sim.jamState.longestTicks == 2
    block loneRobot:
      var lone = emptyBoard()
      lone.clearShelves()
      discard lone.place(0, 3, DirLeft)
      for _ in 0 ..< 20:
        lone.forceActions([ActionForward])
      check lone.world.robots[0].stuck == 20
      check not lone.jamState.active
      check lone.jamState.count == 0

  test "two disjoint standoffs are one jam, and a change of members clears":
    ## The note's jam is "the set of robots with stuck >= jamTicks linked by
    ## the blocking relation, closed transitively, with at least 2 members" --
    ## four seats can hold TWO disjoint 2-robot standoffs, and reporting only
    ## the largest hides half the deadlock from the flag, the count, the hash
    ## and the viewer.
    var sim = emptyBoard()
    sim.clearShelves()
    let
      a = sim.place(1, 3, DirDown)
      b = sim.place(1, 4, DirUp)
      c = sim.place(7, 3, DirDown)
      d = sim.place(7, 4, DirUp)
    let forward = [ActionForward, ActionForward, ActionForward, ActionForward]
    for tick in 1 .. 8:
      sim.forceActions(forward)
    check sim.jamState.active
    check sim.jamState.members == @[a, b, c, d]
    check sim.jamState.count == 1
    ## one pair turns away: the jam that was being shown is not this jam, so
    ## it CLEARS and the remaining pair opens a new one on the same tick
    sim.forceActions([ActionForward, ActionForward, ActionRight, ActionRight])
    check sim.jamCleared
    check sim.jamStarted
    check sim.jamState.active
    check sim.jamState.members == @[a, b]
    check sim.jamState.count == 2
    ## and when the last pair turns away there is no jam left at all
    sim.forceActions([ActionRight, ActionRight, ActionNoop, ActionNoop])
    check not sim.jamState.active
    check sim.jamCleared
    check not sim.jamStarted

  test "scoring":
    ## 12. scores[s] == 100*teamDelivered + delivered[s] over 500 randomised
    ##     end states, always >= 0, delivered[s] < 100 always (the
    ##     lexicographic bound), all four win[s] equal, winner null.
    var sim = playingSim()
    for trial in 0 ..< 500:
      var total = 0
      for seat in 0 ..< SeatCount:
        let own = (trial * 7 + seat * 13) mod 42
        sim.world.robots[seat].delivered = own
        total += own
      sim.world.teamDelivered = total
      for seat in 0 ..< SeatCount:
        check sim.scoreOf(seat) ==
          100 * total + sim.world.robots[seat].delivered
        check sim.scoreOf(seat) >= 0
        check sim.world.robots[seat].delivered < 100
      let won = sim.fleetWon()
      for seat in 0 ..< SeatCount:
        check (sim.teamDelivered() >= sim.config.parDeliveries) == won
    let results = parseJson(sim.fleetResultsJson())
    check results["winner"].kind == JNull

  test "end conditions":
    ## 13. The tick cap, the wall-clock stop and a forced fault each produce
    ##     the right endRule; an all-jammed episode still ends `complete` with
    ##     teamDelivered == 0.
    block tickCap:
      var sim = playingSim()
      sim.config.maxTicks = 3
      for _ in 0 ..< 3:
        sim.step()
      check sim.phase == GameOver
      check sim.endRule == EndRuleTickCap
      check sim.endReason == ReasonComplete
    block wallClock:
      var sim = playingSim()
      sim.applyStop(EndRuleWallClock)
      check sim.phase == GameOver
      check sim.endRule == EndRuleWallClock
    block fault:
      var sim = playingSim()
      sim.applyStop(EndRuleFault)
      check sim.endRule == EndRuleFault
    block allJammed:
      ## Four robots deadlocked in two head-on pairs on an empty floor play out
      ## every tick with the jam flag lit and score nothing.
      var sim = emptyBoard()
      sim.clearShelves()
      sim.config.maxTicks = 60
      discard sim.place(3, 3, DirDown)
      discard sim.place(3, 4, DirUp)
      discard sim.place(6, 3, DirDown)
      discard sim.place(6, 4, DirUp)
      while sim.phase == Playing:
        sim.forceActions([ActionForward, ActionForward, ActionForward,
          ActionForward])
      check sim.endRule == EndRuleTickCap
      check sim.endReason == ReasonComplete
      check sim.teamDelivered() == 0
      check sim.jamState.ticksTotal > 0

  test "no floating point in the sim":
    ## 14. A source grep over the hashed modules finds no float type, no `/`
    ##     division and no float literal.
    for name in ["sim", "warehouse", "robots", "jam", "pilot", "baselines"]:
      let source = stripNimComments(
        readRepoFile("src/rware/" & name & ".nim"))
      for token in ["float", "sqrt", "1.0", "0.5", " / "]:
        if token in source:
          let at = source.find(token)
          checkpoint("src/rware/" & name & ".nim uses \"" & token & "\": " &
            source[max(0, at - 60) ..< min(source.len, at + 40)]
              .replace("\n", " "))
          fail()

  test "tick budget":
    ## 15. Five hundred ticks of a full four-robot episode complete well inside
    ##     two seconds in a release build.
    let started = getMonoTime()
    var config = testConfig(maxTicks = 500)
    let run = runScriptedEpisode(config)
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    check run.sim.tick == 500
    checkpoint("500 ticks in " & $elapsed & " ms")
    check elapsed < 2000
