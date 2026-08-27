## The label contract: the emitted sprite/plate/beat vocabulary equals
## tests/label_manifest.txt, and nothing in it can leak an identity.

import std/[algorithm, json, sequtils, strutils, unittest]
import helpers
import rware/[labels, decide, llm]

suite "rware labels":

  test "the manifest is the emitted vocabulary":
    check labelManifest() == readRepoFile("tests/label_manifest.txt")
    let labels = emittedLabels()
    check labels.len == labels.deduplicate().len
    check labels == labels.sorted()

  test "the two name spaces":
    ## The aliases are the only names that reach an observation, a prompt, an
    ## order, a `say`, a radio line or a sprite label, so a driver can never
    ## learn who it is working with. showPlayerLabels is false, so no in-board
    ## sprite can leak an identity either.
    check IdentityNames.len == SeatCount
    check seatAlias(0) == "Alpha"
    check seatAlias(1) == "Bravo"
    check seatAlias(2) == "Charlie"
    check seatAlias(3) == "Delta"
    for seat in 0 ..< SeatCount:
      check seatAlias(seat) in emittedLabels()
      check seatAliasName(seat) == seatAlias(seat)
    ## the vocabulary is the order verbs, the facings, the stations, the four
    ## seat colours and the four beat kinds -- and no real name is in it
    for word in ["fetch", "deliver", "stow", "yield", "hold",
                 "up", "down", "left", "right", "W1", "W2",
                 "red", "blue", "green", "yellow",
                 "delivery", "jam", "fallback", "end"]:
      check word in emittedLabels()
    let vocabulary = emittedLabels()
    for name in ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"]:
      check name notin vocabulary

  test "showPlayerLabels is false in every shipped config":
    for name in ["warehouse", "wide-hard"]:
      var found = false
      for variant in manifestJson()["variants"]:
        if variant["id"].getStr() == name:
          found = true
          check variant["game_config"]["showPlayerLabels"].getBool() == false
      check found
    check manifestJson()["certification"]["game_config"][
      "showPlayerLabels"].getBool() == false

  test "the observation and the prompt carry NO real name":
    ## The one place an identity could leak into a decision.
    var config = testConfig()
    var engine = initDecisionEngine(config)
    var sim = initSimServer(config)
    sim.seatNames = ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"]
    sim.applyGameStart()
    for seat in 0 ..< SeatCount:
      let view = $engine.seatView(sim, seat, includeNotes = true)
      checkpoint("seat " & $seat)
      for name in ["daveey", "Baseline"]:
        if view.contains(name):
          checkpoint("seat " & $seat & " can see " & name)
          fail()
      check seatAlias(seat) in view
    ## the system prompt and the operator block never name a seat either
    for name in ["daveey", "Baseline"]:
      check not SystemPrompt.contains(name)
      check not operatorBlock("a strategy").contains(name)

  test "the registration record is redacted":
    ## The seat's PROMPT is a secret: the replay gets the policy label, the
    ## kind and the baseline, and nothing else.
    let record = parseJson(registerRecord(
      2, "rware-warehouse-picker", "llm", "courteous"))
    var keys: seq[string]
    for key, _ in record.pairs:
      keys.add(key)
    keys.sort()
    check keys == @["alias", "baseline", "k", "kind", "policy", "slot"]
    check record["alias"].getStr() == "Charlie"
    check record["policy"].getStr() == "rware-warehouse-picker"
