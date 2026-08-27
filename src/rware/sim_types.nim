## Shared types, wire constants and the rune caps.
##
## GameVersion gates replay compatibility. The changelog comment below is
## PREPEND-ONLY (the starter's discipline, kept, with
## `tools/ci/check_gameversion.sh`): say what the number means and what it
## obsoletes, so two branches claiming one number are distinguishable.

import std/[strutils, unicode]

const
  GameVersion* = "1"
    ## GV1 (rware-warehouse v1): semitable/robotic-warehouse ported to a
    ##   10x11 / 16x11 integer grid, four robot seats, one cooperative game
    ##   of 500 ticks and 25 command turns. Obsoletes nothing.

  GameName* = "rware-warehouse"
  ReplayMagic* = "COWLDRWH"
  ReplayFormatVersion* = 1'u16
  ProtocolId* = "rware-warehouse/v1"

  MaxSayRunes* = 120
  MaxNoteRunes* = 240
  MaxPromptRunes* = 4000
  MaxPolicyLabelRunes* = 64
  MaxFallbackDetailRunes* = 200
  MaxStopDetailRunes* = 200
  MaxReplyBytes* = 4096
    ## How much of a provider reply is read before parsing. A BYTE budget --
    ## see `truncateBytes`.
  MaxShelfIdRunes* = 4
  MaxStationRunes* = 2
  MaxVerbRunes* = 8
  MaxDirectiveRunes* = 6000

  SeatCount* = 4
    ## Four seats, always -- both manifest variants and the certification
    ## fixture. One seat drives exactly one robot.
  MaxRobots* = 16
    ## Sprite/object pool ceiling.
  MaxShelves* = 128
    ## Pool ceiling: the widest shipped floor holds 64 shelves.
  MaxRadioLines* = 3
    ## How many `say` lines a seat hears in one observation.
  MaxFreeSlotsReported* = 8
    ## How many visible empty storage cells the observation lists.

  TargetFps* = 30
    ## Presentation frame rate, and the denominator of the playback
    ## accumulator.
  PlaybackSpeeds* = [1, 2, 4, 8]

  ReasonComplete* = "complete"
  ReasonDeadline* = "deadline"
  ReasonFault* = "fault"

  EndRuleTickCap* = "tickCap"
  EndRuleWallClock* = "wallClock"
  EndRuleFault* = "fault"

type
  RwareError* = object of CatchableError
  SimGuardError* = object of RwareError
  ReplayError* = object of RwareError

  Phase* = enum
    Lobby, Playing, GameOver

  SlotConfig* = object
    team*: string
    token*: string

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    seed*: int
    numAgents*: int
    minPlayers*: int
    shelfColumns*: int
    shelfRows*: int
    columnHeight*: int
    requestQueue*: int
    parDeliveries*: int
    maxTicks*: int
    turnTicks*: int
    sensorRange*: int
    jamTicks*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    attempt1Ms*: int
    retryMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    model*: string
    maxOutputTokens*: int
    players*: seq[PlayerConfig]
    slots*: seq[SlotConfig]
    tokens*: seq[string]

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened. Byte truncation is forbidden
  ## anywhere on the path to the replay: a half-codepoint renders in a browser
  ## and then fails a strict UTF-8 parser.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc truncateBytes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` BYTES, never mid-codepoint. For the one cap
  ## that is genuinely a byte budget -- how much of a provider reply is read
  ## before parsing -- where a rune cap would admit up to four times the bytes.
  if limit <= 0:
    return ""
  if text.len <= limit:
    return text
  var cut = limit
  while cut > 0 and (ord(text[cut]) and 0xC0) == 0x80:
    dec cut
  text[0 ..< cut]

proc sanitizeLine*(text: string, limit: int): string =
  ## A recorded free-text field: newlines collapse to spaces so one record
  ## stays one line, then the rune cap applies on a rune boundary.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(limit)

proc sanitizeSay*(text: string): string =
  ## The driver's fleet-radio line. Rune-capped FIRST, then filtered to
  ## printable characters with braces excluded: the replay chat stream tells a
  ## control record from a plain line by a leading '{'.
  result = ""
  for rune in text.sanitizeLine(MaxSayRunes).runes:
    let value = int(rune)
    if value >= 32 and value != ord('{') and value != ord('}') and
        value != 127:
      result.add($rune)
  result = result.strip()
