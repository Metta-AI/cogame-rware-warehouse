## The pilot and the scripted baselines: BOUNDED ORDERS and LEGAL ACTIONS.
##
## Both baselines emit the same object an LLM does, through the same validator,
## which is what makes these assertions meaningful for the LLM path too.

import std/[json, strutils, unicode, unittest]
import helpers

proc pseudoStates(count: int): seq[SimServer] =
  ## `count` pseudo-random but DETERMINISTIC world states: both layouts, every
  ## slot, varying loads, jam states and request boards.
  for trial in 0 ..< count:
    let cols = if trial mod 3 == 0: 5 else: 3
    var sim = playingSim(shelfColumns = cols, seed = 1000 + trial)
    ## walk the fleet forward a pseudo-random number of ticks so the robots are
    ## scattered, some loaded, some blocked
    var engine = scriptedEngine(sim.config)
    let ticks = 7 + (trial * 13) mod 120
    for tick in 0 ..< ticks:
      if tick mod 20 == 0:
        sim.refreshSeatMemory()
        for seat in 0 ..< SeatCount:
          sim.applyOrders(seat, scriptedDirective(
            sim, seat,
            (if (seat + trial) mod 2 == 0: blCourteous else: blShuttle)))
      sim.step()
    ## an empty request board on every seventh state
    if trial mod 7 == 6:
      sim.requestOnly([])
    ## a forced jam on every fifth
    if trial mod 5 == 4:
      for slot in 0 ..< sim.world.robots.len:
        sim.world.robots[slot].blockedLastTurn = 12
    result.add(sim)

suite "rware pilot and baselines":

  test "baselines are bounded":
    ## 16. Over 200 pseudo-random states and BOTH baselines: a verb from the
    ##     enum, a shelf that is currently on the request board, a station in
    ##     {W1, W2}, stow coordinates that are a STORAGE cell, empty say/notes,
    ##     and a serialised directive under 1024 bytes.
    var states = pseudoStates(50)
    var checked = 0
    for sim in states.mitems:
      for baseline in [blShuttle, blCourteous]:
        for seat in 0 ..< SeatCount:
          let directive = scriptedDirective(sim, seat, baseline)
          let order = directive.order
          inc checked
          check directive.say == ""
          check directive.notes == ""
          check directive.source == dsScripted
          case order.kind
          of okFetch:
            check order.shelf >= 0
            check order.shelf < sim.world.shelves.len
            var onBoard = false
            for id in sim.world.requestQueue:
              if id == order.shelf:
                onBoard = true
            if not onBoard:
              checkpoint($baseline & " seat " & $seat &
                " fetched a shelf that is not on the board")
              fail()
          of okDeliver:
            check order.station in [0, 1]
          of okStow:
            if order.hasCell:
              let cell = sim.world.wh.cellIndex(order.x, order.y)
              check sim.world.wh.isStorage(cell)
              check order.x >= 0 and order.x < sim.world.wh.width
              check order.y >= 0 and order.y < sim.world.wh.height
          of okYield, okHold:
            discard
          let record = directive.boundedDirectiveRecord(
            1, seat, sim.world.wh, newJNull())
          check record.len < 1024
    check checked >= 200

  test "pilot never emits an illegal action":
    ## 17. Every emitted action is in the five-way space, TOGGLE_LOAD is never
    ##     emitted while carrying on a highway cell, and no order can leave a
    ##     robot with no action at all.
    var states = pseudoStates(40)
    for sim in states.mitems:
      for kind in OrderKind:
        for seat in 0 ..< SeatCount:
          var probe = sim
          probe.setOrder(seat, kind,
            shelf = (if probe.world.requestQueue.len > 0:
                       probe.world.requestQueue[0] else: -1),
            station = seat mod 2, x = 2, y = 3, hasCell = kind == okStow)
          let step = chooseAction(probe, seat)
          check step.action in [ActionNoop, ActionForward, ActionLeft,
            ActionRight, ActionToggleLoad]
          if step.action == ActionToggleLoad and
              probe.world.robots[seat].carrying >= 0:
            check not probe.world.wh.isHighway(probe.world.robots[seat].cell)

  test "fallback is the courteous proc":
    ## 18. The decision engine's fallback path and the `courteous` baseline
    ##     resolve to the same order, so they cannot drift.
    var states = pseudoStates(20)
    for sim in states.mitems:
      for seat in 0 ..< SeatCount:
        let
          fallback = fallbackDirective(sim, seat)
          courteous = courteousDirective(sim, seat)
        check fallback.order.kind == courteous.order.kind
        check fallback.order.shelf == courteous.order.shelf
        check fallback.order.station == courteous.order.station
        check fallback.order.x == courteous.order.x
        check fallback.order.y == courteous.order.y
        check fallback.source == dsFallback

  test "reply validation":
    ## 19. The validator accepts the schema, REPAIRS an invalid order to the
    ##     seat's previous order, accepts a say-only reply, rejects a
    ##     non-object, truncates say/notes on RUNE boundaries with 4-byte emoji
    ##     sitting on the cap, clamps out-of-range stow coordinates, and never
    ##     leaves a robot unactuated.
    var sim = playingSim()
    let wh = sim.world.wh
    let board = sim.world.requestQueue
    var previous = defaultDirective()
    previous.order = RobotOrder(
      kind: okDeliver, shelf: -1, station: 1, x: -1, y: -1, fromReply: true)

    block accepted:
      let reply = parseJson("""{"verb":"fetch","shelf":"""" &
        shelfLabel(board[0]) & """","say":"taking it","notes":"then stow"}""")
      let got = parseRobotDirective(reply, previous, wh, board)
      check got.order.kind == okFetch
      check got.order.shelf == board[0]
      check got.order.fromReply
      check got.say == "taking it"
      check got.notes == "then stow"
      check got.rejected == 0
    block repaired:
      for bad in ["""{"verb":"fetch","shelf":"S99"}""",
                  """{"verb":"fetch"}""",
                  """{"verb":"charge"}""",
                  """{"verb":"fetch","shelf":"W1"}"""]:
        let got = parseRobotDirective(parseJson(bad), previous, wh, board)
        check got.rejected == 1
        check got.order.kind == previous.order.kind
        check got.order.station == previous.order.station
    block sayOnly:
      let got = parseRobotDirective(
        parseJson("""{"say":"holding column 4"}"""), previous, wh, board)
      check got.rejected == 0
      check got.order.kind == previous.order.kind
      check got.say == "holding column 4"
      check not got.order.fromReply
    block notAnObject:
      expect DirectiveError:
        discard parseRobotDirective(parseJson("[1,2,3]"), previous, wh, board)
      expect DirectiveError:
        discard extractJsonObject("no braces at all here")
    block runeTruncation:
      ## 4-byte emoji sitting EXACTLY on both caps. A byte cut would leave half
      ## a codepoint, and the rune count would not come back as the cap.
      var saySrc = ""
      for _ in 0 ..< 200:
        saySrc.add("\u{1F6E1}")
      var noteSrc = ""
      for _ in 0 ..< 400:
        noteSrc.add("\u{1F525}")
      let got = parseRobotDirective(
        %*{"verb": "hold", "say": saySrc, "notes": noteSrc},
        previous, wh, board)
      check got.say.runeLen == MaxSayRunes
      check got.notes.runeLen == MaxNoteRunes
      check got.say.validateUtf8() == -1
      check got.notes.validateUtf8() == -1
      ## and the record that carries them is still valid JSON
      let record = got.boundedDirectiveRecord(3, 0, wh, newJNull())
      check record.validateUtf8() == -1
      discard parseJson(record)
    block clampedStow:
      let got = parseRobotDirective(
        %*{"verb": "stow", "x": 9999, "y": -40}, previous, wh, board)
      check got.order.kind == okStow
      check got.order.x >= 0 and got.order.x < wh.width
      check got.order.y >= 0 and got.order.y < wh.height
    block neverUnactuated:
      ## Every reply above, applied to a live seat, still leaves the pilot with
      ## an action.
      for text in ["""{"verb":"fetch","shelf":"S99"}""", """{"say":"hi"}""",
                   """{"verb":"stow","x":9999,"y":-40}""",
                   """{"verb":"yield"}""", """{"verb":"hold"}"""]:
        var probe = sim
        let got = parseRobotDirective(
          parseJson(text), probe.directives[0], wh, board)
        probe.applyOrders(0, got)
        let step = chooseAction(probe, 0)
        check step.action in [ActionNoop, ActionForward, ActionLeft,
          ActionRight, ActionToggleLoad]

  test "the reply byte cap is a byte cap on a rune boundary":
    ## MaxReplyBytes is genuinely a BYTE budget -- a rune cap there would admit
    ## up to four times the bytes into parseJson -- but the cut still lands on
    ## a codepoint boundary.
    var body = ""
    for _ in 0 ..< 4000:
      body.add("\u{1F525}")
    let cut = body.truncateBytes(MaxReplyBytes)
    check cut.len <= MaxReplyBytes
    check cut.validateUtf8() == -1
    check cut.len mod 4 == 0

  test "the pilot's park rule keeps the workstation queue lane clear":
    var sim = playingSim()
    let
      laneLeft = sim.world.wh.width div 2 - 1
      laneRight = sim.world.wh.width div 2
    for seat in 0 ..< SeatCount:
      let park = parkCell(sim, seat)
      check park >= 0
      check sim.world.wh.isHighway(park)
      check sim.world.wh.cellX(park) notin [laneLeft, laneRight]

  test "an equal-cost fetch is broken by the lowest shelf id":
    ## design.md:638 (`shuttle` rule 3) and :652 (`courteous` rule 4) both pin
    ## "ties by lowest shelf id". The request QUEUE is in draw order, so an
    ## iteration-order tie-break would make the choice depend on delivery
    ## history instead of on the board.
    for baseline in [blShuttle, blCourteous]:
      for queueOrder in [@[1, 0], @[0, 1]]:
        var sim = emptyBoard()
        sim.clearShelves()
        let slot = sim.place(2, 4, DirUp)
        ## two storage cells one step from the robot, so the BFS costs tie
        let
          low = sim.world.wh.storageOf[sim.cellOf(2, 3)]
          high = sim.world.wh.storageOf[sim.cellOf(1, 4)]
        check low >= 0 and high >= 0 and low < high
        sim.standShelf(low, 2, 3)
        sim.standShelf(high, 1, 4)
        sim.requestOnly(
          if queueOrder == @[1, 0]: [high, low] else: [low, high])
        let order = scriptedDirective(sim, slot, baseline).order
        check order.kind == okFetch
        check order.shelf == low

  test "hold stands still, wherever the robot is standing":
    ## `hold` is NOOP every tick and never finishes: a driver that says "hold"
    ## in a jam standoff must not have its robot drive to a park cell instead.
    var sim = emptyBoard()
    sim.clearShelves()
    let
      laneLeft = sim.world.wh.width div 2 - 1
      onStorage = sim.place(1, 1, DirUp)
      inQueueLane = sim.place(laneLeft, sim.world.wh.height - 2, DirUp)
    for slot in [onStorage, inQueueLane]:
      sim.setOrder(slot, okHold)
      ## the park cell is somewhere else, so a park-driven `hold` would move
      check parkCell(sim, slot) != sim.world.robots[slot].cell
      for tick in 0 ..< 4:
        let step = chooseAction(sim, slot)
        check step.action == ActionNoop
        check step.outcome == orRunning
        sim.forceActions([ActionNoop, ActionNoop])
      check sim.world.robots[slot].cell ==
        (if slot == onStorage: sim.cellOf(1, 1)
         else: sim.cellOf(laneLeft, sim.world.wh.height - 2))

  test "an order that finishes reports honestly":
    ## `last_order_result` is the pilot's report of WHY the previous order
    ## ended, which is what lets a seat recover from a race with an unseen
    ## robot.
    var sim = emptyBoard()
    sim.clearShelves()
    let slot = sim.place(1, 1, DirUp)
    sim.requestOnly([0])
    sim.setOrder(slot, okFetch, shelf = 0)
    check chooseAction(sim, slot).outcome == orShelfGone
    sim.setOrder(slot, okDeliver, station = 0)
    check chooseAction(sim, slot).outcome == orNotLoaded
    sim.setOrder(slot, okStow)
    check chooseAction(sim, slot).outcome == orNotLoaded
    sim.standShelf(0, 1, 1)
    sim.world.robots[slot].carrying = 0
    sim.world.shelves[0].carrier = slot
    sim.world.rebuildLayers()
    sim.setOrder(slot, okFetch, shelf = 0)
    check chooseAction(sim, slot).outcome == orAlreadyLoaded

  test "baseline names parse tolerantly and default to the published one":
    check parseBaseline("shuttle") == blShuttle
    check parseBaseline("COURTEOUS") == blCourteous
    check parseBaseline("  courteous  ") == blCourteous
    check parseBaseline("") == DefaultBaseline
    check parseBaseline("nonsense") == DefaultBaseline
    check DefaultBaseline == blCourteous
