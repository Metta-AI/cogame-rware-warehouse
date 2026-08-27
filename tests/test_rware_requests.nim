## The request stream is SEEDED AND UNSTEERABLE -- the idea's anti-collusion
## pin, asserted rather than asserted-in-prose.
##
## The k-th refill is a pure function of `(seed, k)`, where k is the number of
## deliveries so far. It is never consumed by anything else, so no pair of
## seats can arrange the queue between them by choosing who delivers, in what
## order, or at which workstation.

import std/unittest
import helpers

proc deliverAt(sim: var SimServer, station, slot: int) =
  ## Walks one robot onto a workstation carrying a requested shelf, so a test
  ## can force a delivery without playing an episode.
  let shelf = sim.world.requestQueue[0]
  sim.world.shelves[shelf].carrier = slot
  sim.world.robots[slot].carrying = shelf
  sim.world.robots[slot].cell = sim.world.wh.goals[station]
  sim.world.shelves[shelf].cell = sim.world.wh.goals[station]
  sim.world.robots[slot].facing = DirUp
  sim.world.rebuildLayers()
  var steps = newSeq[PilotStep](sim.world.robots.len)
  for i in 0 ..< steps.len:
    steps[i] = PilotStep(action: ActionNoop, outcome: orRunning)
  sim.resolveTick(steps)

proc requestSequence(
  seed: int, deliveries: int, station: int, slots: openArray[int]
): seq[int] =
  ## The shelves the board asks for, in order, when `deliveries` deliveries are
  ## made at `station` by the robots in `slots` (cycled).
  var sim = initSimServer(testConfig(seed = seed))
  sim.applyGameStart()
  result.add(sim.world.requestQueue)
  for k in 0 ..< deliveries:
    sim.deliverAt(station, slots[k mod slots.len])
    result.add(sim.world.requestQueue)

suite "rware request stream":

  test "a refill draw is a pure function of (seed, k)":
    for seed in [1, 42, 4242]:
      var first = initSimServer(testConfig(seed = seed))
      first.applyGameStart()
      for k in 0 ..< 20:
        let a = first.world.refillDraw(seed, k)
        let b = first.world.refillDraw(seed, k)
        check a == b
        check a >= 0
        check not first.world.requested[a]

  test "the sequence does not depend on WHICH seat delivered":
    ## Same seed, same number of deliveries, different robots doing the
    ## delivering: byte-identical request sequences.
    for seed in [7, 42, 31337]:
      let byAlpha = requestSequence(seed, 12, 0, [0])
      let byDelta = requestSequence(seed, 12, 0, [3])
      let roundRobin = requestSequence(seed, 12, 0, [0, 1, 2, 3])
      check byAlpha == byDelta
      check byAlpha == roundRobin

  test "the sequence does not depend on WHICH workstation took the shelf":
    for seed in [7, 42, 31337]:
      check requestSequence(seed, 10, 0, [0]) ==
        requestSequence(seed, 10, 1, [0])

  test "a different seed gives a different stream":
    ## Not a strict requirement of the pin, but a stream that ignored the seed
    ## would pass every test above while making every episode identical.
    let a = requestSequence(11, 10, 0, [0])
    let b = requestSequence(12, 10, 0, [0])
    check a != b

  test "the board never holds a duplicate and always holds requestQueue ids":
    var sim = initSimServer(testConfig(seed = 99))
    sim.applyGameStart()
    for k in 0 ..< 30:
      check sim.world.requestQueue.len == sim.config.requestQueue
      var seen: seq[int]
      for id in sim.world.requestQueue:
        check id notin seen
        seen.add(id)
        check sim.world.requested[id]
      var flagged = 0
      for id in 0 ..< sim.world.requested.len:
        if sim.world.requested[id]:
          inc flagged
      check flagged == sim.world.requestQueue.len
      sim.deliverAt(k mod 2, 0)

  test "the refill draws from upstream's candidate set":
    ## warehouse.py:915-917 evaluates `candidates = [s for s in self.shelfs if
    ## s not in self.request_queue]` BEFORE the delivered shelf's queue entry
    ## is replaced, so the shelf just delivered is not a candidate for its own
    ## replacement and the candidate set is exactly
    ## `shelves - requestQueue` at every refill. Transcribed here and compared
    ## against what the port actually draws.
    for seed in [7, 42, 99]:
      var sim = initSimServer(testConfig(seed = seed))
      sim.applyGameStart()
      for k in 0 ..< 25:
        let
          delivered = sim.world.requestQueue[0]
          before = sim.world.requestQueue
        ## upstream's candidate list, in ascending shelf id, taken BEFORE the
        ## queue entry is replaced
        var candidates: seq[int]
        for id in 0 ..< sim.world.shelves.len:
          if id notin before:
            candidates.add(id)
        let want = candidates[
          streamDraw(seed, StreamRequest, k, candidates.len)]
        sim.deliverAt(0, 0)
        check sim.world.teamDelivered == k + 1
        check delivered notin sim.world.requestQueue
        check sim.world.requestQueue[0] == want
        check sim.world.requested[want]
        ## stow the delivered shelf back on its home slot, so the pad is clear
        ## for the next delivery
        let carried = sim.world.robots[0].carrying
        if carried >= 0:
          sim.world.robots[0].carrying = -1
          sim.world.shelves[carried].carrier = -1
          sim.world.shelves[carried].cell = sim.world.shelves[carried].home
          sim.world.rebuildLayers()

  test "the spawn draw is seeded too, and independent of the request stream":
    ## Both streams derive from the seed and neither consumes the other, so
    ## the spawn is a function of the seed alone.
    for seed in [3, 44, 555]:
      let a = initWorld(3, 1, 8, 4, 4, 3, seed)
      let b = initWorld(3, 1, 8, 4, 4, 3, seed)
      for slot in 0 ..< a.robots.len:
        check a.robots[slot].cell == b.robots[slot].cell
        check a.robots[slot].facing == b.robots[slot].facing
      check a.requestQueue == b.requestQueue
