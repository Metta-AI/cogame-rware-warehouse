## Replay forensics: expand a binary `COWLDRWH` replay into a readable dump.
##
## `tools/replay_summary.py` is the machine-readable view (Python 3 stdlib
## only, so a phase-60 check needs nothing installed). THIS is the human one:
## it uses the game's own codec, so it can print the per-tick hash chain, the
## re-derived board and the point a divergence appears -- the things a JSON
## summary cannot show.
##
##   nim r --path:src tools/expand_replay.nim <replay> [--ticks N] [--board T]
##
##   --ticks N   print the first N order/chat records (default 40)
##   --board T   print the re-derived warehouse at tick T

import std/[json, os, strformat, strutils]
import ../src/rware/[sim, replays, replay_runtime, roster]

proc boardAt(data: ReplayData, tick: int): string =
  var runtime = initReplayRuntime(data)
  var game = runtime.sim
  while runtime.player.frame <= min(tick, runtime.player.maxFrame):
    runtime.player.advanceReplayFrame(game)
  let wh = game.world.wh
  var rows: seq[string]
  for y in 0 ..< wh.height:
    var row = ""
    for x in 0 ..< wh.width:
      let cell = wh.cellIndex(x, y)
      let robot = game.world.robotAtCell(cell)
      if robot >= 0:
        row.add(seatAlias(robot)[0])
      elif cell == wh.goals[0] or cell == wh.goals[1]:
        row.add('W')
      elif game.world.standingShelfAt(cell) >= 0:
        row.add(if game.world.requested[game.world.standingShelfAt(cell)]: '*'
                else: '#')
      elif wh.isHighway(cell):
        row.add('.')
      else:
        row.add(' ')
    rows.add(row)
  rows.add(&"tick {game.tick} delivered {game.teamDelivered()} " &
    &"jam {game.jamState.active} hash {game.gameHashHex()}")
  rows.join("\n")

when isMainModule:
  let args = commandLineParams()
  if args.len == 0:
    quit("usage: expand_replay <replay> [--ticks N] [--board T]", 2)
  var
    path = ""
    ticks = 40
    boardTick = -1
    i = 0
  while i < args.len:
    case args[i]
    of "--ticks":
      inc i
      ticks = parseInt(args[i])
    of "--board":
      inc i
      boardTick = parseInt(args[i])
    else:
      path = args[i]
    inc i
  if path.len == 0:
    quit("usage: expand_replay <replay> [--ticks N] [--board T]", 2)

  let data = parseReplayBytes(readFile(path))
  echo &"game        {data.gameName} v{data.gameVersion}"
  echo &"config      {data.configJson}"
  echo &"joins       {data.joins.len}  orders {data.orders.len}  " &
    &"chats {data.chats.len}  hashes {data.hashes.len}  stops {data.stops.len}"
  echo &"frames      {data.frameCount}"
  for record in data.joins:
    echo &"  join      tick {record.tick} slot {record.slot} " &
      &"name {record.name}"
  for record in data.stops:
    echo &"  stop      tick {record.tick} endRule {record.endRule}"

  echo "--- orders"
  var shown = 0
  let wh = initWarehouse(
    parseInt(data.configField("shelfColumns")),
    parseInt(data.configField("shelfRows")),
    parseInt(data.configField("columnHeight")))
  for record in data.orders:
    if shown >= ticks:
      break
    inc shown
    echo &"  t{record.tick:>4} turn {record.turn:>2} {seatAlias(record.slot)}" &
      &"  {record.order.kind} {orderArg(record.order, wh)}"

  echo "--- chats"
  shown = 0
  for record in data.chats:
    if shown >= ticks:
      break
    inc shown
    var kind = "?"
    var extra = ""
    if record.text.startsWith("{"):
      try:
        let node = parseJson(record.text)
        kind = node{"k"}.getStr("?")
        case kind
        of "directive":
          extra = node{"alias"}.getStr() & " " & node{"source"}.getStr() &
            " " & node{"verb"}.getStr() & " " & node{"arg"}.getStr()
          let say = node{"say"}.getStr()
          if say.len > 0:
            extra.add(" say=\"" & say & "\"")
        of "fallback":
          extra = "slot " & $node{"slot"}.getInt() & " attempt " &
            $node{"attempt"}.getInt() & " " & node{"cause"}.getStr()
        of "register":
          extra = "slot " & $node{"slot"}.getInt() & " " &
            node{"policy"}.getStr() & " " & node{"kind"}.getStr()
        of "result":
          extra = $node{"results"}{"reason"} & " delivered " &
            $node{"results"}{"teamDelivered"}
        else:
          extra = record.text.truncateRunes(120)
      except CatchableError:
        extra = record.text.truncateRunes(120)
    else:
      extra = record.text.truncateRunes(120)
    echo &"  t{record.tick:>4} {kind:<12} {extra}"

  echo "--- integrity"
  var runtime = initReplayRuntime(data)
  var game = runtime.sim
  while runtime.player.frame <= runtime.player.maxFrame:
    runtime.player.advanceReplayFrame(game)
  if runtime.player.hashMismatchTick >= 0:
    echo &"  HASH MISMATCH at tick {runtime.player.hashMismatchTick}"
  else:
    echo &"  hash chain clean over {data.hashes.len} ticks"
  echo &"  final: tick {game.tick} delivered {game.teamDelivered()} " &
    &"reason {game.endReason} endRule {game.endRule}"

  if boardTick >= 0:
    echo "--- board"
    echo boardAt(data, boardTick)
