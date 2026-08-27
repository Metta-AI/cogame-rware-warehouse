## The broadcast layer: the per-frame state packet the viewer chrome consumes,
## the roster block, and `stepEvents` -- the derived event stream.
##
## The TEN event kinds are DERIVED from state deltas and from the replay's chat
## records during playback, so they cost no replay bytes and are identical live
## and in replay:
##
##   turn {n}                order {slot, verb, arg}      say {slot, text}
##   fallback {slot, cause}  load {slot, shelf, cell}     stow {slot, shelf, cell}
##   deliver {slot, shelf, station, total}
##   jam {slots, cells, tick}  jamclear {slots, ticks}
##   end {reason, teamDelivered, par}
##
## Only `delivery`, `jam`, `fallback` and `end` become scrubber BEATS; `turn`,
## `order`, `say`, `load` and `stow` drive the feed.

import std/[json, strutils]
import sim, replays, replay_runtime, roster, global

type
  BroadcastTracker* = object
    sentOnce*: bool

proc initBroadcastTracker*(): BroadcastTracker =
  discard

proc phaseText*(phase: Phase): string =
  case phase
  of Lobby: "lobby"
  of Playing: "playing"
  of GameOver: "gameover"

proc stepEvents*(
  sim: SimServer, tracker: var BroadcastTracker, chats: seq[ChatRecord]
): JsonNode =
  ## Everything that happened in the frame just stepped, in one array. A pure
  ## function of the sim delta plus the frame's chat records.
  result = newJArray()
  for mark in sim.lastLoads:
    result.add(%*{
      "k": "load", "slot": mark.slot, "shelf": shelfLabel(mark.shelf),
      "cell": [sim.world.wh.cellX(sim.world.robots[mark.slot].cell),
               sim.world.wh.cellY(sim.world.robots[mark.slot].cell)]})
  for mark in sim.lastDeliveries:
    result.add(%*{
      "k": "deliver", "slot": mark.slot, "shelf": shelfLabel(mark.shelf),
      "station": stationLabel(mark.station),
      "total": sim.teamDelivered()})
  for mark in sim.lastStows:
    result.add(%*{
      "k": "stow", "slot": mark.slot, "shelf": shelfLabel(mark.shelf),
      "cell": [sim.world.wh.cellX(sim.world.shelves[mark.shelf].cell),
               sim.world.wh.cellY(sim.world.shelves[mark.shelf].cell)]})
  ## A jam whose MEMBERSHIP changed closes and reopens on the same tick, so
  ## the clear comes first and the feed reads jam -> jamclear -> jam.
  if sim.jamCleared:
    result.add(%*{
      "k": "jamclear", "slots": newJArray(), "ticks": sim.jamClearedTicks})
  if sim.jamStarted:
    var slots = newJArray()
    var cells = newJArray()
    for slot in sim.jamState.members:
      slots.add(%slot)
      cells.add(%[sim.world.wh.cellX(sim.world.robots[slot].cell),
        sim.world.wh.cellY(sim.world.robots[slot].cell)])
    result.add(%*{
      "k": "jam", "slots": slots, "cells": cells, "tick": sim.tick})
  for record in chats:
    if record.text.len == 0 or record.text[0] != '{':
      continue
    var node: JsonNode
    try:
      node = parseJson(record.text)
    except CatchableError:
      continue
    if node.kind != JObject:
      continue
    case node{"k"}.getStr()
    of "directive":
      let slot = node{"slot"}.getInt(0)
      result.add(%*{"k": "turn", "n": node{"turn"}.getInt(0)})
      result.add(%*{
        "k": "order", "slot": slot,
        "verb": node{"verb"}.getStr(),
        "arg": node{"arg"}.getStr()})
      let say = node{"say"}.getStr()
      if say.len > 0:
        result.add(%*{"k": "say", "slot": slot, "text": say})
    of "fallback":
      result.add(%*{
        "k": "fallback", "slot": node{"slot"}.getInt(0),
        "cause": node{"cause"}.getStr()})
    else:
      discard
  if sim.phase == GameOver and sim.gameOverHold == 1:
    result.add(%*{
      "k": "end",
      "reason": sim.endRule,
      "teamDelivered": sim.teamDelivered(),
      "par": sim.config.parDeliveries
    })

const SeatColours* = ["red", "blue", "green", "yellow"]
  ## Cosmetic and fixed by slot: Alpha red, Bravo blue, Charlie green, Delta
  ## yellow -- the four colours the starter ships soldier art in.

proc rosterJson*(sim: SimServer): JsonNode =
  ## One entry per seat, in the shape chrome_common's naming and momentum code
  ## already reads. `name` is the REAL policy name (spectator side only);
  ## `alias` is the in-game anonymous name.
  result = newJArray()
  for seat in 0 ..< SeatCount:
    result.add(%*{
      "s": seat,
      "name": sim.seatNames[seat],
      "alias": seatAlias(seat),
      "pol": sim.seatNames[seat],
      "team": SeatColours[seat],
      "lives": sim.deliveredBy(seat),
      "alive": true,
      "kind": sim.seatPolicyKind[seat]
    })

proc seatsJson(sim: SimServer): JsonNode =
  result = newJArray()
  for seat in 0 ..< SeatCount:
    result.add(%*{
      "slot": seat,
      "alias": seatAlias(seat).toUpperAscii(),
      "name": sim.seatNames[seat],
      "colour": SeatColours[seat],
      "delivered": sim.deliveredBy(seat),
      "stowed": sim.stowedBy(seat),
      "blocked": sim.blockedBy(seat),
      "fallbacks": sim.fallbackTurns[seat],
      "kind": sim.seatPolicyKind[seat],
      "carrying": (if seat < sim.world.robots.len and
                      sim.world.robots[seat].carrying >= 0:
                     %shelfLabel(sim.world.robots[seat].carrying)
                   else: newJNull())
    })

proc teamsJson(sim: SimServer): JsonNode =
  ## One "team" per seat colour, so chrome_common's naming helpers keep working
  ## on a byte-identical file. `lives` is that seat's delivered count.
  result = newJObject()
  for seat in 0 ..< SeatCount:
    result[SeatColours[seat]] = %*{
      "lives": sim.deliveredBy(seat),
      "policies": [sim.seatNames[seat]]
    }

proc endcardJson(sim: SimServer): JsonNode =
  if sim.phase != GameOver:
    return newJNull()
  var rows = newJArray()
  for seat in 0 ..< SeatCount:
    rows.add(%*{
      "alias": seatAlias(seat).toUpperAscii(),
      "name": sim.seatNames[seat],
      "colour": SeatColours[seat],
      "delivered": sim.deliveredBy(seat),
      "stowed": sim.stowedBy(seat),
      "blocked": sim.blockedBy(seat),
      "jams": sim.jamState.count
    })
  %*{
    "rows": rows,
    "teamDelivered": sim.teamDelivered(),
    "par": sim.config.parDeliveries,
    "met": sim.fleetWon(),
    "score": sim.scoreOf(0),
    "jams": sim.jamState.count,
    "jamTicks": sim.jamState.ticksTotal,
    "longestJamTicks": sim.jamState.longestTicks,
    "reason": sim.endReason,
    "complete": true
  }

proc buildStateJson*(
  sim: SimServer,
  player: ReplayPlayer,
  tracker: var BroadcastTracker,
  events: JsonNode,
  live: bool
): string =
  ## One frame. The chrome fields (`t`, `st`, `mx`, `mt`, `ph`, `pl`, `sp`,
  ## `teams`, `roster`, `lulls`, `beats`, `lead`) are the starter's, so
  ## `chrome_common.js` drives the clock, the transport, the scrubber, the
  ## beats and the momentum graph unchanged. Everything this game adds lives
  ## under `rw`.
  let
    startFrame =
      if player.gameStartFrames.len > 0: player.gameStartFrames[0] else: 0
    axisTick = if live: sim.tick else: max(0, player.frame - 1)
    axisStart = if live: 0 else: startFrame
    axisMax =
      if live: max(1, sim.config.maxTicks)
      else: max(startFrame + 1, player.maxFrame)
  var node = %*{
    "t": axisTick,
    "st": axisStart,
    "mx": axisMax,
    "mt": sim.config.maxTicks,
    "ph": phaseText(sim.phase),
    "lob": max(0, sim.config.lobbyJoinTimeoutTicks - sim.lobbyTicks),
    "pl": player.playing,
    "lp": player.looping,
    "sk": player.skipLulls,
    "ff": player.fastForward,
    "sp": player.playbackSpeed(),
    "en": true,
    "pov": -1,
    "teams": teamsJson(sim),
    "roster": rosterJson(sim),
    "gv": GameVersion,
    "rw": {
      "board": boardJson(sim),
      "turn": sim.turnIndex,
      "turns": sim.turnsPerEpisode(),
      "tick": sim.tick,
      "maxTicks": sim.config.maxTicks,
      "robots": robotsJson(sim),
      "shelves": shelvesJson(sim),
      "requests": requestsJson(sim),
      "deliveries": deliveriesJson(sim),
      "jam": jamJson(sim),
      "seats": seatsJson(sim),
      "delivered": sim.teamDelivered(),
      "par": sim.config.parDeliveries,
      "blocked": sim.blockedBy(0) + sim.blockedBy(1) + sim.blockedBy(2) +
        sim.blockedBy(3),
      "jams": sim.jamState.count,
      "mismatchTick": player.hashMismatchTick,
      "endcard": endcardJson(sim),
      "events": events
    }
  }
  if not tracker.sentOnce and not live:
    tracker.sentOnce = true
    node["lulls"] = player.lullsJson()
    node["beats"] = player.beatsJson()
    node["lead"] = player.leadJson()
    node["jamspans"] = player.jamSpansJson()
  if live:
    node["live"] = %true
  $node
