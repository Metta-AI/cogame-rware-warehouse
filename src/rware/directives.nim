## The order schema: what a driver (LLM or scripted) may say, how a reply is
## parsed TOLERANTLY, and how an illegal order is REPAIRED to that seat's
## previous order rather than dropped.
##
## Both policy kinds emit the same object through this one validator, which is
## what makes the bounded-orders test in tests/test_rware_pilot.nim meaningful.
##
## RUNE DISCIPLINE. Every cap here is measured in runes and every truncation
## lands on a rune boundary (`truncateRunes`). Byte slicing anywhere on the
## path to the replay is forbidden.

import std/[json, strutils, unicode]
import sim_types, warehouse

type
  OrderKind* = enum
    okFetch = "fetch"
    okDeliver = "deliver"
    okStow = "stow"
    okYield = "yield"
      ## spelled `yield` on the wire; `okYield` here because `yield` is a Nim
      ## keyword.
    okHold = "hold"

  RobotOrder* = object
    kind*: OrderKind
    shelf*: int          ## fetch: shelf index, else -1
    station*: int        ## deliver: 0 (W1) or 1 (W2)
    x*, y*: int          ## stow: the named cell
    hasCell*: bool       ## stow: were coordinates given?
    fromReply*: bool     ## the reply really named an order

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  RobotDirective* = object
    ## One seat's whole order for one turn: this game issues exactly one.
    order*: RobotOrder
    say*: string         ## <= MaxSayRunes, the fleet radio
    notes*: string       ## <= MaxNoteRunes, private, echoed back next turn
    source*: DirectiveSource
    latencyMs*: int
    rejected*: int       ## orders repaired because they did not validate

  DirectiveError* = object of ValueError

const IdentityNames* = ["Alpha", "Bravo", "Charlie", "Delta"]

proc seatAliasName*(seat: int): string =
  IdentityNames[seat mod IdentityNames.len]

proc defaultOrder*(): RobotOrder =
  ## Turn 1's default before any reply lands: hold station, do nothing that
  ## could deadlock the aisle. The scripted `courteous` order replaces it on
  ## the very first turn.
  RobotOrder(kind: okHold, shelf: -1, station: 0, x: -1, y: -1)

proc defaultDirective*(): RobotDirective =
  result.order = defaultOrder()
  result.source = dsScripted

proc parseOrderKind*(text: string): tuple[ok: bool, kind: OrderKind] =
  ## Tolerant: lower-cased, hyphens and spaces normalised, capped at
  ## MaxVerbRunes. An unrecognised verb reports `ok = false` so the caller
  ## repairs to the seat's previous order instead of inventing one.
  let key = text.strip().truncateRunes(MaxVerbRunes).toLowerAscii()
    .replace("-", "_").replace(" ", "_")
  for kind in OrderKind:
    if $kind == key:
      return (true, kind)
  (false, okHold)

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readInt(node: JsonNode): tuple[ok: bool, value: int] =
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt: (true, int(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0) else: (true, int(f))
  of JString:
    try: (true, int(parseFloat(node.getStr().strip())))
    except CatchableError: (false, 0)
  else: (false, 0)

proc parseRobotDirective*(
  payload: JsonNode,
  previous: RobotDirective,
  wh: Warehouse,
  requestBoard: openArray[int]
): RobotDirective =
  ## Turns one parsed reply into a legal directive, REPAIRING every field the
  ## schema bounds rather than rejecting the reply:
  ##
  ## * a reply with a valid `say` but no `verb` is USABLE -- the seat keeps its
  ##   current order and the radio line is delivered;
  ## * an unknown verb, a `fetch` naming a shelf that is not on the request
  ##   board -> the seat's PREVIOUS order, counted in `rejected`, never dropped
  ##   into "unactuated";
  ## * a `deliver` with no or an unknown station defaults to W1 (the pilot
  ##   re-picks the nearer station when none was named);
  ## * `stow` coordinates are CLAMPED into [0,width) x [0,height);
  ## * `say` and `notes` are rune-truncated at their caps.
  ##
  ## Raises DirectiveError only when the payload is not an object -- the one
  ## condition the retry and then the scripted fallback exist for.
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result = previous
  result.source = dsLlm
  result.rejected = 0
  result.say = sanitizeSay(payload{"say"}.getStr())
  result.notes = sanitizeLine(payload{"notes"}.getStr(), MaxNoteRunes)
  result.order.fromReply = false
  let verbText = payload{"verb"}.getStr()
  if verbText.strip().len == 0:
    ## A say-only reply: keep the standing order, deliver the radio line.
    return
  let verb = parseOrderKind(verbText)
  if not verb.ok:
    inc result.rejected
    return
  var order = RobotOrder(
    kind: verb.kind, shelf: -1, station: 0, x: -1, y: -1, hasCell: false)
  case verb.kind
  of okFetch:
    let shelf = parseShelfLabel(payload{"shelf"}.getStr(), wh.shelfCount())
    var onBoard = false
    for id in requestBoard:
      if id == shelf:
        onBoard = true
    if shelf < 0 or not onBoard:
      inc result.rejected
      return
    order.shelf = shelf
  of okDeliver:
    let station = parseStationLabel(payload{"station"}.getStr())
    order.station = max(0, station)
  of okStow:
    let
      rx = readInt(payload{"x"})
      ry = readInt(payload{"y"})
    if rx.ok and ry.ok:
      order.x = clamp(rx.value, 0, wh.width - 1)
      order.y = clamp(ry.value, 0, wh.height - 1)
      order.hasCell = true
  of okYield, okHold:
    discard
  order.fromReply = true
  result.order = order

proc orderArg*(order: RobotOrder, wh: Warehouse): string =
  ## The order's argument as one short spectator-facing string.
  case order.kind
  of okFetch: (if order.shelf >= 0: shelfLabel(order.shelf) else: "")
  of okDeliver: stationLabel(order.station)
  of okStow: (if order.hasCell: $order.x & "," & $order.y else: "nearest")
  else: ""

proc orderJson*(order: RobotOrder, wh: Warehouse): JsonNode =
  %*{"verb": $order.kind, "arg": orderArg(order, wh)}

proc directiveRecord*(
  directive: RobotDirective,
  turn, seat: int,
  wh: Warehouse,
  view: JsonNode
): JsonNode =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED fields only: it drives the broadcast feed and
  ## tools/replay_summary.py and can never affect the simulation.
  %*{
    "k": "directive",
    "turn": turn,
    "slot": seat,
    "alias": seatAliasName(seat),
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "verb": $directive.order.kind,
    "arg": orderArg(directive.order, wh),
    "say": directive.say.truncateRunes(MaxSayRunes),
    "view": view
  }

proc boundedDirectiveRecord*(
  directive: RobotDirective,
  turn, seat: int,
  wh: Warehouse,
  view: JsonNode
): string =
  ## The serialized record, guaranteed <= MaxDirectiveRunes. `say` is the only
  ## field that can grow, so it is the one that shrinks -- and the cut still
  ## lands on a rune boundary. The SERIALIZED string is never sliced: that
  ## would emit broken JSON, the exact failure the rune rule prevents.
  var trimmed = directive
  result = $trimmed.directiveRecord(turn, seat, wh, view)
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 16:
    inc guard
    trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 16))
    result = $trimmed.directiveRecord(turn, seat, wh, view)
