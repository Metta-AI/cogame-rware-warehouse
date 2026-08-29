## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, the playback tick rate, the rune
## caps the text layout reserves room for). Rendered ONCE, from the same Nim
## consts the engine runs on; server.nim splices the block into every served
## client page and tools/gen_wire_constants.nim emits it for the static wasm
## bundle. Clients read `window.RWARE_WIRE`.

import std/strutils
import sim_types, replay_runtime

proc jsSpeedArray(values: openArray[int]): string =
  ## The chip row, slowest first. Half speed LEADS the engine's whole-number
  ## multipliers: it is a sentinel speedIndex rather than a `PlaybackSpeeds`
  ## entry (replay_runtime.ReplayHalfSpeedIndex), so it is prepended here.
  result = "[0.5"
  for v in values:
    result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  "window.RWARE_WIRE={speeds:" & jsSpeedArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",tickRate:" & $TicksPerSecondBase &
  ",maxSayRunes:" & $MaxSayRunes &
  ",maxRobots:" & $MaxRobots &
  ",maxShelves:" & $MaxShelves &
  ",seats:" & $SeatCount &
  ",gameVersion:\"" & GameVersion & "\"" &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads window.RWARE_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
