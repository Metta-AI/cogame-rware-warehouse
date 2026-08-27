## The label vocabulary contract: every string this game can put on a sprite,
## a plate, a beat button or a feed row, enumerated in one place.
##
## `tests/label_manifest.txt` is the pinned copy and `test_rware_labels.nim`
## asserts the two agree, so a label change has to be regenerated in the same
## commit. The vocabulary is deliberately scoped to the ANONYMOUS name space:
## no real policy name is ever a label (showPlayerLabels is false), which is
## the anti-collusion half of the two-name-space rule.

import std/[algorithm, strutils]
import sim_types, upstream, directives, roster, warehouse

proc emittedLabels*(): seq[string] =
  for seat in 0 ..< SeatCount:
    result.add(seatAlias(seat))
    result.add(seatAlias(seat).toUpperAscii())
  for kind in OrderKind:
    result.add($kind)
  for facing in ["up", "down", "left", "right"]:
    result.add(facing)
  for station in 0 ..< GoalCount:
    result.add(stationLabel(station))
  for colour in ["red", "blue", "green", "yellow"]:
    result.add(colour)
  for kind in ["delivery", "jam", "fallback", "end"]:
    result.add(kind)
  result.sort()

proc labelManifest*(): string =
  emittedLabels().join("\n") & "\n"
