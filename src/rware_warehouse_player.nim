## The rware-warehouse player container runs numeric policies over the
## ordinary seat socket. Prompt policies still use the game-side LLM client.
##
##   PLAYER_PROMPT        a strategy in plain English -> this seat is an LLM seat
##   PLAYER_SCRIPTED      shuttle | courteous                -> this seat is scripted
##   PLAYER_NUMERIC_URL   an /actions endpoint                -> numeric seat
##   PLAYER_POLICY_LABEL  a free label for the replay's `register` record
##
## A seat that sets neither is `courteous`. To field a numeric policy, reuse
## this image and set PLAYER_NUMERIC_URL on the player:
##
##   coworld upload-policy <rware-warehouse-image> --name my-rware \
##     --run /bin/rware-warehouse-player --env PLAYER_NUMERIC_URL="<endpoint>"

import std/[json, options, os, random, strutils, times]
import bitworld/spriteprotocol
import whisky
import rware/sim_types
import rware/numeric_policy

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 24
  ReconnectAttempts = 6

## The two caps below come from `rware/sim_types` -- the SAME constants and the
## SAME rune-boundary `truncateRunes` the server enforces them with. They were
## re-declared here once, which meant 4000/64 existed twice and could drift
## (r1 review F15).

proc registrationBlob(prompt, scripted, policy: string,
                      external: bool): string =
  ## The one registration message. `scripted` is JSON null when the seat is an
  ## LLM seat, so the server can tell "no baseline named" from "courteous
  ## named explicitly".
  var node = %*{
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "prompt": prompt.truncateRunes(MaxPromptRunes)
  }
  if scripted.len > 0:
    node["scripted"] = %scripted
  else:
    node["scripted"] = newJNull()
  if external:
    node["mode"] = %"external"
  blobFromSpriteChat($node)

proc orderBlob(request, order: JsonNode): string =
  blobFromSpriteChat("orders:" & $request["turn"].getInt() & ":" & $order)

proc readyBlob(): string =
  ## The Sprite v1 player-ready packet (0x85). Legitimate here in a way it is
  ## not for an ordinary player client: this seat sends NO inputs at all (the
  ## server computes every robot's action), so the dead-reckoning hazard
  ## cannot arise, and a fastMode server can advance as soon as every seat has
  ## acknowledged the frame.
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip()
    scripted = getEnv("PLAYER_SCRIPTED").strip()
    numeric = getEnv("PLAYER_NUMERIC_URL").strip().len > 0
    external = numeric
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif numeric: "numeric"
      elif prompt.len > 0: "prompt"
      elif scripted.len > 0: scripted
      else: "courteous"
  echo "rware-warehouse player: kind=",
    (if external: "external" elif prompt.len > 0: "llm" else: "scripted"),
    " baseline=", (if scripted.len > 0: scripted else: "courteous"),
    " label=", label
  if external and (prompt.len > 0 or scripted.len > 0):
    quit("Choose exactly one player policy mode", 1)
  randomize()
  let session = "rware:" & $getCurrentProcessId() & ":" &
    $getTime().toUnix() & ":" & $rand(high(int))

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The episode runner starts the players at the same
    ## instant as the game, so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "rware-warehouse player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("rware-warehouse player: game never accepted a connection", 1)
  echo "rware-warehouse player: connected"

  # Each session is wrapped: whisky's receiveMessage RAISES on a close frame or
  # a truncated read (only a timeout returns none), and mummy's send only
  # QUEUES -- so the game's own quit(0) can outrun the flushed frame. A naive
  # player exits 1 on that race and fails certification intermittently
  # (cogame-raid 0.1.3). Exiting 0 on a dead socket is the fix.
  #
  # REGISTRATION IS RE-SENT, NOT SENT ONCE. Joins are slot-sequential, so a
  # seat whose slot is not the next open one is not admitted until the lower
  # slots have joined -- and the lobby sends frames to a socket before it is
  # admitted, so both the first registration and a single re-send keyed on the
  # first received frame can land while the seat has no index yet (paintball
  # round 3, 2026-08-25). This end keeps re-sending for the first ~10 s of
  # frames; registering twice is harmless, the server just re-reads the same
  # fields.
  var reconnects = 0
  while true:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(prompt, scripted, label, external),
        BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue                    ## a read timeout, not a closed socket
        inc sessionFrames
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(prompt, scripted, label, external),
            BinaryMessage)
        if external and received.get().kind == TextMessage:
          let request = parseJson(received.get().data)
          if request["type"].getStr() == "decision":
            let order = chooseNumericOrder(request, session)
            socket.send(orderBlob(request, order), BinaryMessage)
        socket.send(readyBlob(), BinaryMessage)
    except CatchableError as error:
      echo "rware-warehouse player: socket closed (", error.msg, ")"
    # NEVER exit while the game is still serving: a seat that drops keeps its
    # army for the whole episode and revives on reconnect. Bounded on both
    # counts, so this can never outlive the game or spin.
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "rware-warehouse player: re-dialling the seat (attempt ", reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "rware-warehouse player: game is no longer listening, exiting cleanly"
      break
    echo "rware-warehouse player: reconnected, re-registering"
  quit(0)
