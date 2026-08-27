## The endcard and chrome VOCABULARY gate.
##
## A forked ctf endcard silently ships paintbot's words: nothing in the
## starter's tests, in `viewer_smoke.mjs` or in the label manifest covers
## spectator chrome STRINGS, because `labels.nim` deliberately scopes itself to
## the policy contract. So the re-labelings are enumerated in the design note
## and enforced here -- zero forbidden words, and every replacement present.

import std/[strutils, unittest]
import helpers

const
  Forbidden = ["Lives", "LIVES", "Clstr", "Cap<", "flag", "heart", "paint",
               "hopper", "hill", "POV", "spray", "grenade", "med kit"]
    ## The design note's list, minus `kill`: `#killfeed` is one of the ids the
    ## same note lists as KEPT, so a literal `kill` gate would fail on the
    ## inherited markup it requires. Every paintbot NOUN is still here.
  # The design note's re-mapping table, left column -> right column:
  #   ec-thead Player/K/D/Clstr/Cap  ->  Robot/Delivered/Stowed/Blocked/Jams
  #   fl-cap "Lives left"            ->  "Shelves delivered"
  #   momentum-label "LIVES LEAD"    ->  "DELIVERIES"
  #   plate "lives-label Lives"      ->  "deliv-label Delivered"
  #   lk-cap hoppers/paint line      ->  "Charging the robots..."
  #   clock-caption locker room      ->  "Powering up"
  #   mmwarn "recorded inputs"       ->  "recorded orders" (with the tick)
  #   btn-spoilers "flag story"      ->  "deliveries / jams / result"
  RequiredOnce = [
    "<span>Robot</span>",
    "<span>Delivered</span>",
    "<span>Stowed</span>",
    "<span>Blocked</span>",
    "<span>Jams</span>",
    "Shelves delivered",
    "DELIVERIES",
    "Powering up",
    "deliveries / jams / result"
  ]
  # Present, but legitimately more than once, with the reason:
  #   deliv-label              a CLASS: the markup that emits it, its own CSS
  #                            rule and the .tiny rule that hides it
  #   Charging the robots      the curtain's static caption in markup, and the
  #                            first entry of the rotating prep-talk list
  #   showing recorded orders  the inherited static #mmwarn text, and the JS
  #                            that rewrites it with the mismatch tick
  RequiredPresent = [
    "deliv-label",
    "Charging the robots",
    "showing recorded orders"
  ]

proc withoutComments(text: string): string =
  ## HTML comments, CSS comments and `//` line comments removed. A comment
  ## explaining what was deleted is documentation; a STRING the spectator reads
  ## is vocabulary, and only the latter is under test.
  var body = text
  for (opener, closer) in [("<!--", "-->"), ("/*", "*/")]:
    var scan = 0
    while true:
      let start = body.find(opener, scan)
      if start < 0:
        break
      let stop = body.find(closer, start)
      if stop < 0:
        body = body[0 ..< start]
        break
      body = body[0 ..< start] & body[stop + closer.len .. ^1]
      scan = start
  var lines: seq[string]
  for line in body.splitLines():
    let at = line.find("//")
    if at >= 0 and line[0 ..< at].count('"') mod 2 == 0 and
        line[0 ..< at].count('\'') mod 2 == 0:
      lines.add(line[0 ..< at])
    else:
      lines.add(line)
  lines.join("\n")

suite "rware endcard labels":

  test "zero paintbot vocabulary outside comments":
    for path in ["client/replay_broadcast.html", "client/broadcast_core.js",
                 "client/page_script.js", "client/game_block.html"]:
      let text = withoutComments(readRepoFile(path))
      for word in Forbidden:
        if word in text:
          let at = text.find(word)
          checkpoint(path & " still says \"" & word & "\": ..." &
            text[max(0, at - 70) ..< min(text.len, at + 40)].replace("\n", " ") &
            "...")
          fail()

  test "every re-mapped string is present exactly once":
    ## Present is not enough: a re-mapping that ships BOTH words (the new
    ## caption added and the old one left behind in a second rule) reads as a
    ## pass to a presence check.
    let page = withoutComments(readRepoFile("client/replay_broadcast.html"))
    for wanted in RequiredOnce:
      let seen = page.count(wanted)
      if seen != 1:
        checkpoint("the re-mapped string appears " & $seen & " times, not 1: " &
          wanted)
        fail()
    for wanted in RequiredPresent:
      if wanted notin page:
        checkpoint("the re-mapped string is missing: " & wanted)
        fail()

  test "the feed speaks plain language, not internal notation":
    let block1 = readRepoFile("client/game_block.html")
    for phrase in ["lifts ", "delivers ", "stows ", "JAM \\u2014",
                   "JAM CLEARED AFTER", "MISSED THE CALL"]:
      check phrase in block1
    ## the clock reads the fleet's delivered count and the par, not a countdown
    let script = readRepoFile("client/page_script.js")
    check "'DELIVERED ' + rw.delivered" in script
    check "'/ ' + rw.par + ' par" in script
    check "tick ' + rw.tick + '/' + rw.maxTicks" in script

  test "the two name spaces are respected in the chrome":
    ## The seat's REAL policy name is spectator side only; the in-game alias is
    ## what a driver ever sees. Both appear on the plate, and nothing in the
    ## board layer draws a real name.
    let script = readRepoFile("client/page_script.js")
    check "plate-name" in script
    check "plate-alias" in script
    check "teamHeadline(seat.name" in script
    let core = readRepoFile("client/broadcast_core.js")
    check "seat.name" notin core
    check "roster" notin core
