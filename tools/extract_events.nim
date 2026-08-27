## Re-derive the tier-2 analysis stream from a recorded replay.
##
## `COGAME_EVENTS_URI` gets this stream live, from the running game. A replay
## carries only the inputs and the hash chain, so the events have to be
## RE-DERIVED -- by the same sim module, from the same records -- which is
## exactly what proves they were derived and not recorded in the first place.
##
##   nim r --path:src tools/extract_events.nim <replay> [--jsonl|--counts]
##
## `--jsonl` prints the same JSON-lines shape the live stream writes,
## including the mandatory trailing summary row. `--counts` (the default)
## prints one line per event kind with its total.

import std/[json, os, strformat, strutils, tables]
import ../src/rware/[sim, replays, replay_runtime, broadcast, roster]

when isMainModule:
  let args = commandLineParams()
  if args.len == 0:
    quit("usage: extract_events <replay> [--jsonl|--counts]", 2)
  var
    path = ""
    jsonl = false
  for arg in args:
    case arg
    of "--jsonl": jsonl = true
    of "--counts": jsonl = false
    else: path = arg
  if path.len == 0:
    quit("usage: extract_events <replay> [--jsonl|--counts]", 2)

  let data = parseReplayBytes(readFile(path))
  var runtime = initReplayRuntime(data)
  var game = runtime.sim
  game.applyJoinRecords(data)
  for record in data.chats:
    game.applyReplayChat(record.text)
  var tracker = initBroadcastTracker()
  var
    counts = initOrderedTable[string, int]()
    total = 0
    lines: seq[string]
  while runtime.player.frame <= runtime.player.maxFrame:
    let tick = runtime.player.frame
    runtime.player.advanceReplayFrame(game)
    for event in stepEvents(game, tracker, runtime.player.pending):
      let kind = event{"k"}.getStr()
      counts.mgetOrPut(kind, 0) += 1
      inc total
      if jsonl:
        var row = copy(event)
        row["tick"] = %tick
        lines.add($row)

  if jsonl:
    for line in lines:
      echo line
    echo $(%*{
      "type": "summary",
      "ticks": game.episodeTick,
      "events": total,
      "gameVersion": GameVersion
    })
  else:
    echo &"{data.gameName} v{data.gameVersion}: {total} derived events over " &
      &"{runtime.player.maxFrame + 1} frames"
    for kind, count in counts.pairs:
      echo &"  {kind:<12} {count:>6}"
    echo &"  delivered {game.teamDelivered()} of par " &
      &"{game.config.parDeliveries}, jams {game.jamState.count}, " &
      &"jam ticks {game.jamState.ticksTotal}"
    if runtime.player.hashMismatchTick >= 0:
      quit(&"HASH MISMATCH at tick {runtime.player.hashMismatchTick}", 1)
