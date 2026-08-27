## Determinism: the same seed and the same order stream produce a byte-identical
## episode, and the replay's bytes are enough to re-derive it on a FRESH sim.

import std/unittest
import helpers
import rware/replay_runtime

suite "rware determinism":

  test "the same seed and the same orders replay identically":
    var config = testConfig(maxTicks = 300)
    let a = runScriptedEpisode(config)
    let b = runScriptedEpisode(config)
    check a.bytes == b.bytes
    check a.sim.gameHash() == b.sim.gameHash()
    check a.sim.teamDelivered() == b.sim.teamDelivered()
    check a.sim.fleetResultsJson() == b.sim.fleetResultsJson()

  test "a fresh sim re-derives every tick from the seed and the orders alone":
    var config = testConfig(maxTicks = 300)
    let run = runScriptedEpisode(config)
    let data = parseReplayBytes(run.bytes)
    ## the config comes out of the BYTES, not out of the test's own variable
    var back = initSimServer(configFromReplay(data))
    var orderCursor = 0
    var frame = 0
    var hashCursor = 0
    while frame < data.frameCount:
      for record in data.gameStarts:
        if record.tick == frame:
          back.applyGameStart()
      while orderCursor < data.orders.len and
          data.orders[orderCursor].tick == frame:
        let record = data.orders[orderCursor]
        var directive = back.directives[record.slot]
        directive.order = record.order
        back.applyOrders(record.slot, directive)
        inc orderCursor
      for record in data.stops:
        if record.tick == frame:
          back.applyStop(record.endRule)
      back.advanceFrame()
      if hashCursor < data.hashes.len and
          data.hashes[hashCursor].tick == frame:
        check back.gameHash() == data.hashes[hashCursor].value
        inc hashCursor
      inc frame
    check hashCursor == data.hashes.len
    check back.tick == run.sim.tick
    check back.teamDelivered() == run.sim.teamDelivered()
    for seat in 0 ..< SeatCount:
      check back.deliveredBy(seat) == run.sim.deliveredBy(seat)
      check back.stowedBy(seat) == run.sim.stowedBy(seat)
      check back.blockedBy(seat) == run.sim.blockedBy(seat)
    check back.jamState.ticksTotal == run.sim.jamState.ticksTotal

  test "both shipped layouts re-derive":
    for cols in [3, 5]:
      var config = testConfig(shelfColumns = cols, maxTicks = 200,
        requestQueue = (if cols == 3: 4 else: 2))
      let run = runScriptedEpisode(config)
      var back = initReplayRuntime(
        parseReplayBytes(run.bytes), mismatchQuit = true)
      while back.player.frame <= back.player.maxFrame:
        back.player.advanceReplayFrame(back.sim)
      check back.player.hashMismatchTick == -1
      check back.sim.teamDelivered() == run.sim.teamDelivered()

  test "a different seed is a different episode":
    let a = runScriptedEpisode(testConfig(maxTicks = 200, seed = 11))
    let b = runScriptedEpisode(testConfig(maxTicks = 200, seed = 12))
    check a.bytes != b.bytes

  test "the hash mixes every field the design pins":
    ## Flip one field at a time and require the hash to change. A field that
    ## is not mixed is a field a divergence can hide behind.
    var sim = playingSim()
    let base = sim.gameHash()
    block robotCell:
      var probe = sim
      probe.world.robots[0].cell += 1
      check probe.gameHash() != base
    block robotFacing:
      var probe = sim
      probe.world.robots[0].facing = turn(probe.world.robots[0].facing,
        ActionRight)
      check probe.gameHash() != base
    block carrying:
      var probe = sim
      probe.world.robots[0].carrying = 3
      check probe.gameHash() != base
    block stuck:
      var probe = sim
      probe.world.robots[0].stuck = 4
      check probe.gameHash() != base
    block shelfCell:
      var probe = sim
      probe.world.shelves[0].cell += 1
      check probe.gameHash() != base
    block shelfCarrier:
      var probe = sim
      probe.world.shelves[0].carrier = 2
      check probe.gameHash() != base
    block queue:
      var probe = sim
      probe.world.requestQueue[0] = probe.world.requestQueue[0] + 1
      check probe.gameHash() != base
    block delivered:
      var probe = sim
      probe.world.teamDelivered = 9
      check probe.gameHash() != base
      var own = sim
      own.world.robots[2].delivered = 5
      check own.gameHash() != base
    block stowed:
      var probe = sim
      probe.world.robots[1].stowed = 3
      check probe.gameHash() != base
    block jamMembers:
      var probe = sim
      probe.jamState.members = @[0, 1]
      check probe.gameHash() != base
    block tick:
      var probe = sim
      probe.tick += 1
      check probe.gameHash() != base
