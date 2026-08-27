## The manifest pins. Every one of these is a release that fails two phases
## later if it is only checked by eye.

import std/[json, sets, strutils, unittest]
import helpers

proc keySet(node: JsonNode): HashSet[string] =
  for key, _ in node.pairs:
    result.incl(key)

suite "rware manifest":

  test "num_agents is four, inside every game_config and nowhere else":
    let manifest = manifestJson()
    check manifest["variants"].len == 2
    for variant in manifest["variants"]:
      ## CoworldVariant is additionalProperties:false and the platform reads
      ## only game_config.num_agents (goofspiel-oshi-zumo 0.1.0)
      check variant{"num_agents"}.isNil
      check variant["game_config"]["num_agents"].getInt() == SeatCount
      check variant["game_config"]["minPlayers"].getInt() == SeatCount
      check variant["game_config"]["players"].len == SeatCount
      check variant{"id"}.getStr().len > 0
      check variant{"name"}.getStr().len > 0
      check variant{"description"}.getStr().len > 0
    let cert = manifest["certification"]
    check cert{"num_agents"}.isNil
    check cert["game_config"]["num_agents"].getInt() == SeatCount

  test "no game_config carries a literal tokens array":
    ## matriculate rejects "game_config must not include runner-managed
    ## tokens" (knights-archers 0.1.0), while config_schema keeps REQUIRING it
    ## because the runner injects it.
    let manifest = manifestJson()
    for variant in manifest["variants"]:
      check variant["game_config"]{"tokens"}.isNil
    check manifest["certification"]["game_config"]{"tokens"}.isNil
    check "tokens" in manifest["game"]["config_schema"]["required"].to(
      seq[string])

  test "the four SEAT-COUNT invariants docker_smoke.sh cross-checks":
    let cert = manifestJson()["certification"]
    check cert["game_config"]["num_agents"].getInt() == SeatCount
    check cert["players"].len == SeatCount
    check cert["game_config"]["players"].len == SeatCount
    ## and SMOKE_SEATS, the independent second declaration
    let smoke = readRepoFile("tools/ci/docker_smoke.sh")
    check "seats_expected=\"${SMOKE_SEATS:-" & $SeatCount & "}\"" in smoke

  test "every declared player occupies a certification slot":
    ## Cert `players-run` fails players_missing the moment the manifest
    ## declares a runnable the fixture never seats (raid 0.1.2).
    let manifest = manifestJson()
    check manifest["player"].len == 2
    var seated: HashSet[string]
    for entry in manifest["certification"]["players"]:
      seated.incl(entry["player_id"].getStr())
    for player in manifest["player"]:
      check player["id"].getStr() in seated
      check player["type"].getStr() == "player"
      check player["name"].getStr().startsWith("rware-warehouse-")
      check player["description"].getStr().len > 0
      check player["source_url"].getStr().len > 0
      check player["image"].getStr() == "{{RWARE_WAREHOUSE_IMAGE}}"
      check player["run"].to(seq[string]) == @["/bin/rware-warehouse-player"]
      ## limits.cpu minimum is "1" (pistonball 0.1.1)
      check player["resources"]["limits"]["cpu"].getStr() == "1"
      check player["resources"]["requests"]["cpu"].getStr() == "100m"
    ## the cert fixture seats courteous, shuttle, courteous, shuttle
    var order: seq[string]
    for entry in manifest["certification"]["players"]:
      order.add(entry["player_id"].getStr())
    check order == @["courteous", "shuttle", "courteous", "shuttle"]

  test "every array in config_schema declares minItems and maxItems":
    ## tandem 0.1.0: cert fails manifest_invalid on any array property without
    ## bounds, not just the required ones.
    let properties = manifestJson()["game"]["config_schema"]["properties"]
    var arrays = 0
    for name, prop in properties.pairs:
      if prop{"type"}.getStr() != "array":
        continue
      inc arrays
      checkpoint("config_schema." & name)
      check not prop{"minItems"}.isNil
      check not prop{"maxItems"}.isNil
    check arrays >= 3
    check manifestJson()["game"]["config_schema"]["additionalProperties"]
      .getBool() == false

  test "the manifest's shape matches the 0.1.42+ upload contract":
    let manifest = manifestJson()
    check manifest{"$schema"}.getStr().len > 0
    check manifest["tags"].len >= 3
    check manifest{"episode_timeout_minutes"}.getInt() == 20
    check manifest{"version"}.isNil                 ## no TOP-LEVEL version
    let game = manifest["game"]
    check game["name"].getStr() == GameName
    check game["owner"].getStr().len > 0
    check game["description"].getStr().len > 0
    check game{"tags"}.isNil                        ## tags live top level only
    check game{"display_name"}.isNil
    check game["replay_viewer"]["bundle"].getStr() == "static-replay-viewer"
    check manifest{"replay_viewer"}.isNil           ## under `game`, not top
    check game["runnable"]["type"].getStr() == "game"
    check game["runnable"]["run"].to(seq[string]) == @["/bin/rware-warehouse"]
    check game["runnable"]["env"]["ANTHROPIC_API_KEY_URI"].getStr() ==
      "secret://coworld/" & GameName & "/anthropic_api_key"

  test "protocols and docs are objects, not bare strings":
    ## garble v0.1.0: the platform validator rejects bare strings, and repo CI
    ## does not catch it.
    let game = manifestJson()["game"]
    for side in ["player", "global"]:
      let node = game["protocols"][side]
      check node.kind == JObject
      check node["type"].getStr().len > 0
      check node["value"].getStr().len > 0
    let docs = game["docs"]
    check docs["readme"]["type"].getStr().len > 0
    check docs["readme"]["value"].getStr().len > 0
    check docs["pages"].len == 2
    for page in docs["pages"]:
      check page["id"].getStr().len > 0
      check page["title"].getStr().len > 0
      check page["content"]["type"].getStr().len > 0
      check page["content"]["value"].getStr().len > 0

  test "the embedded docs equal the files they were embedded from":
    ## tools/embed_manifest_docs.py is the single writer of that block.
    let docs = manifestJson()["game"]["docs"]
    check docs["readme"]["value"].getStr() == readRepoFile("README.md")
    check docs["pages"][0]["content"]["value"].getStr() ==
      readRepoFile("docs/RULES.md")
    check docs["pages"][1]["content"]["value"].getStr() ==
      readRepoFile("docs/PORTING-RWARE.md")

  test "results_schema is the closed set fleetResultsJson emits":
    let manifest = manifestJson()
    let declared = keySet(manifest["game"]["results_schema"]["properties"])
    var sim = playingSim()
    let emitted = keySet(parseJson(sim.fleetResultsJson()))
    checkpoint("only in the manifest: " & $(declared - emitted))
    checkpoint("only in the results: " & $(emitted - declared))
    check declared == emitted
    check manifest["game"]["results_schema"]["additionalProperties"]
      .getBool() == false
    check manifest["game"]["results_schema"]["properties"]["reason"]["enum"]
      .to(seq[string]) == @[ReasonComplete, ReasonDeadline, ReasonFault]

  test "every wallClockBudgetSeconds stays inside 60% of the episode budget":
    let manifest = manifestJson()
    let budget = manifest["episode_timeout_minutes"].getInt() * 60
    let ceiling = budget * 6 div 10
    for variant in manifest["variants"]:
      let value = variant["game_config"]["wallClockBudgetSeconds"].getInt()
      checkpoint(variant["id"].getStr())
      check value <= 660
      check value <= ceiling
    check manifest["certification"]["game_config"]["wallClockBudgetSeconds"]
      .getInt() == 240

  test "every variant's game_config constructs and generates what it claims":
    ## collab-cooking 0.1.1: test EVERY variant, not just the fixture. A
    ## variant that does not construct schedules zero episodes, and the cert
    ## fixture is too small to notice.
    let manifest = manifestJson()
    var configs: seq[(string, JsonNode)]
    for variant in manifest["variants"]:
      configs.add((variant["id"].getStr(), variant["game_config"]))
    configs.add(("certification", manifest["certification"]["game_config"]))
    for (name, node) in configs:
      checkpoint(name)
      var config = defaultGameConfig()
      config.update($node)
      check config.numAgents == SeatCount
      check config.minPlayers == SeatCount
      check config.players.len == SeatCount
      let wh = initWarehouse(
        config.shelfColumns, config.shelfRows, config.columnHeight)
      case name
      of "warehouse", "certification":
        check (wh.width, wh.height) == (10, 11)
        check wh.shelfCount() == 32
        check config.requestQueue == 4
        check config.parDeliveries == 8
      of "wide-hard":
        check (wh.width, wh.height) == (16, 11)
        check wh.shelfCount() == 64
        check config.requestQueue == 2
        check config.parDeliveries == 5
      else: discard
      ## and a real episode runs to completion under it
      config.turnSpacingMs = 0
      config.gameOverTicks = 2
      config.lobbyJoinTimeoutTicks = 1
      config.maxTicks = 120
      let run = runScriptedEpisode(config)
      check run.sim.endReason == ReasonComplete
      check run.state.finished

  test "the policy set is two prompts and two scripted baselines":
    let policies = parseJson(readRepoFile("tools/ci/policies.json"))
    check policies.len == 4
    var prompts, scripted = 0
    var owners: seq[string]
    for policy in policies:
      check policy["run"].getStr() == "/bin/rware-warehouse-player"
      check policy["name"].getStr().startsWith("rware-warehouse-")
      if not policy["env"]{"PLAYER_PROMPT"}.isNil:
        inc prompts
        check policy["env"]["PLAYER_PROMPT"].getStr().len > 200
      if not policy["env"]{"PLAYER_SCRIPTED"}.isNil:
        inc scripted
        check policy["env"]["PLAYER_SCRIPTED"].getStr() in
          ["shuttle", "courteous"]
      if not policy{"player"}.isNil:
        owners.add(policy["player"].getStr())
    check prompts == 2
    check scripted == 2
    ## champion #2 is uploaded while daveey-1 is the active player
    check owners == @["ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"]
    check policies[1]{"player"}.getStr() ==
      "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    ## the two prompts are DIFFERENT strategies, not one text twice
    check policies[0]["env"]["PLAYER_PROMPT"].getStr() !=
      policies[1]["env"]["PLAYER_PROMPT"].getStr()

  test "compose declares one underscored service the placeholder derives from":
    let compose = readRepoFile("compose.yaml")
    check "  rware_warehouse:" in compose
    check "image: coworld-rware-warehouse:latest" in compose
    check "platform: linux/amd64" in compose
    check "network: host" in compose
    check "dockerfile: Dockerfile" in compose
    check "{{RWARE_WAREHOUSE_IMAGE}}" in readRepoFile(
      "coworld_manifest_template.json")

  test "no scaffold placeholder survived substitution":
    let needles = ["<" & "slug>", "<" & "IMAGE>", "<" & "SEATS>"]
    for path in [".github/workflows/ci.yml",
                 ".github/workflows/coworld-release.yml",
                 ".github/workflows/coworld-submit.yml",
                 "tools/ci/docker_smoke.sh", "tools/ci/policies.json",
                 "coworld_manifest_template.json", "compose.yaml"]:
      let text = readRepoFile(path)
      for needle in needles:
        if needle in text:
          checkpoint(path & " still carries " & needle)
          fail()
