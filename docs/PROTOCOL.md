# Protocol

## The Coworld contract

| Direction | Env var / route | What |
|---|---|---|
| in | `COGAME_CONFIG_URI` | the episode's `game_config` JSON |
| out | `COGAME_RESULTS_URI` | the results document below |
| out | `COGAME_SAVE_REPLAY_URI` | the `COWLDRWH` replay bytes |
| out | `COGAME_PLAYER_FAILURE_URI` | `{"message", "failed_policy_index"}` and nothing else |
| out | `COGAME_EVENTS_URI` | the tier-2 JSON-lines analysis stream (`file://` only) |
| in | `COGAME_LOAD_REPLAY_URI` | local replay mode |
| in | `HOST` / `PORT` / `COGAME_HOST` / `COGAME_PORT` | the bind address |

Routes:

| Route | What |
|---|---|
| `GET /healthz` | the runner's liveness probe |
| `WS /player?slot=<i>&token=<t>` | one seat; the token is checked against the configured roster |
| `WS /global` | the spectator status feed; one JSON state object per frame |
| `GET /client/player?slot&token` | served for real, token-checked, and it does **not** open the player socket |
| `GET /client/global` | served for real |
| `GET /client/replay` | the developer-local broadcast page (never declared to the platform) |
| `GET /client/*` | the font, the board art and the robot-bay art |
| `GET /replay-data` | the recorded bytes, for local tooling |

Both `/client` routes are registered **before** any catch-all asset route, and
`/healthz` and `/global` keep answering for a bounded 20 s grace after the
artifacts are written — the certifier pings them **after** the player pods start,
and a short episode can already have finished by then.

The serve thread runs independently of the game loop, so a 14 s LLM stall cannot
drop a connection or stall `/healthz`. Global broadcasts are fire and forget, so
a slow viewer can never stall the episode.

## The seat

`/bin/rware-warehouse-player` is deliberately thin. It dials its seat with bounded
retries, sends ONE Sprite v1 chat message carrying its registration, and then only
receives:

```json
{"policy": "<label>", "prompt": "<PLAYER_PROMPT or empty>",
 "scripted": "shuttle" | "courteous" | null}
```

`prompt` is rune-truncated at 4000 runes and `policy` at 64. Every decision is
made **inside the game server**, because that is the only container the platform
injects the `anthropic_api_key` coworld secret into.

Two details are scar tissue, not style:

- **The registration is re-sent** for the first ~10 s of received frames. Joins
  are slot-sequential, and the lobby sends frames to a socket before it is
  admitted, so a first registration can land while the seat has no index yet.
- **The seat exits 0 on a dead socket.** whisky's `receiveMessage` raises on a
  close frame and mummy's `send` only queues, so the game's own `quit(0)` can
  outrun the flushed frame. Exiting 1 there fails certification intermittently.

A seat's chat is its **registration** and nothing else: it is consumed by the
server, never applied as a shout and never written to the replay chat stream (the
prompt is a secret). What the replay gets is a redacted `register` record with the
policy label and kind only. Any other chat text from a seat is dropped —
drivers speak through `say`, seats do not shout.

## The observation

A JSON object appended to the user message, and mirrored (minus `your_notes`)
into the replay's `directive` record so the replay explains every decision.

```json
{
  "you": "Charlie",
  "fleet": ["Alpha", "Bravo", "Charlie", "Delta"],
  "turn": 7, "of": 25, "tick": 120, "turn_ticks": 20, "ticks_left": 380,
  "warehouse": {"width": 10, "height": 11,
                "stations": {"W1": [4, 10], "W2": [5, 10]},
                "storage_slots": 32, "sensor_range": 3},
  "requests": [{"shelf": "S07", "home": [1, 3]},
               {"shelf": "S12", "home": [7, 4]},
               {"shelf": "S19", "home": [2, 6]},
               {"shelf": "S28", "home": [8, 8]}],
  "you_are": {"cell": [3, 6], "facing": "down", "loaded": true,
              "carrying": "S19", "order": "deliver W1", "order_age_turns": 2,
              "last_order_result": "running", "blocked_ticks_last_turn": 6,
              "on_aisle": true},
  "seen": {
    "robots": [{"alias": "Alpha", "cell": [3, 4], "facing": "down",
                "loaded": false},
               {"alias": "Delta", "cell": [4, 7], "facing": "up",
                "loaded": true}],
    "free_slots": [[2, 5], [2, 7], [1, 8]],
    "shelves_here": [{"shelf": "S22", "cell": [2, 6], "requested": false}]},
  "radio": [{"from": "Alpha", "text": "taking S07, I will come down column 3"},
            {"from": "Delta", "text": "W2 is mine, someone clear the queue lane"}],
  "fleet_status": {"delivered": 9, "par": 8, "jam": true,
                   "jam_robots": ["Charlie", "Delta"], "jam_ticks": 6},
  "your_notes": "after S19 stow at (2,7) and pick up S28"
}
```

**Visible.** The whole floor plan (sent once at registration as an ASCII map,
`#` storage slot, `.` aisle, `W` workstation, then referred to by coordinates);
the request board in full, with each shelf's home cell; everything about the
seat's own robot; other robots and cell contents within Chebyshev
`sensor_range = 3`; every seat's previous-turn `say` on the fleet radio; and the
public fleet statistics.

`facing` is one of `up|down|left|right`. `last_order_result` is one of
`running|done|shelf_gone|no_path|no_free_slot|not_loaded|already_loaded` — the
pilot's honest report of why the previous order ended. `free_slots` lists at most
8 visible empty storage cells, nearest first. `radio` carries at most 3 lines,
each already truncated to 120 runes. `requests` is always exactly
`requestQueue` entries long, so the array shape never changes.

**Hidden.** Every other seat's current order and `notes`; every other seat's real
player name, policy name and kind; robots and shelf-slot occupancy outside the
sensor radius; which robot is carrying which shelf unless that robot is inside
the radius; the request RNG's future draws; and the other seats' fallback and
decision statistics. Nothing about any seat's identity ever reaches a prompt.

## The reply

```json
{"verb": "fetch", "shelf": "S12", "say": "taking S12, keep column 7 clear",
 "notes": "then stow at (2,7)"}
```

| Field | Cap / domain |
|---|---|
| `verb` | <= 8 runes; `fetch` \| `deliver` \| `stow` \| `yield` \| `hold`, lower-cased before matching |
| `shelf` | required iff `verb == "fetch"`; <= 4 runes; must be an id currently on the request board |
| `station` | optional when `verb == "deliver"`; <= 2 runes; `W1` \| `W2` |
| `x`, `y` | optional when `verb == "stow"`; clamped into `[0,width)` x `[0,height)`; a clamped cell that is not an empty storage cell degrades to the nearest known free slot |
| `say` | <= 120 runes; the fleet radio, heard by every seat next turn |
| `notes` | <= 240 runes; private, echoed to this seat only next turn |
| whole reply | <= 4096 bytes read from the provider before parsing |
| `PLAYER_PROMPT` | <= 4000 runes at registration |

`yield` is spelled `yield` on the wire and `okYield` in the Nim enum, because
`yield` is a Nim keyword.

Unknown top-level keys are ignored. A reply with a valid `say` but no `verb` is a
**usable** reply: the seat keeps its current order and the radio line is
delivered. A reply that is not a JSON object is a parse failure — one retry, then
the `courteous` fallback. An order whose verb is valid but whose required
argument is missing or unknown is **repaired to the seat's previous order**, not
dropped, and counted in `ordersRejected`.

### Why a turn fell back

Every fallback is written to the replay as a `fallback` chat record carrying the
seat, the attempt and a `cause` from exactly this set:

| `cause` | The turn fell back because |
|---|---|
| `timeout` | the per-turn budget was exhausted before this attempt could start |
| `transport_error` | the request failed at the transport (connection, TLS, non-timeout curl error) |
| `parse_error` | a reply arrived and was not a usable order after the retry |
| `throttled` | the provider answered 429 and no other candidate model was left, so the retry batch is skipped |
| `rate_guard` | issuing this batch would push the trailing-60 s request count over 28, the sidecar's 30/min cap |
| `no_credentials` | no API key (or the provider rejected it), so the LLM leg is off |
| `budget_guard` | two more turns would not fit the wall-clock budget; the rest of the episode plays scripted |
| `disconnected` | the seat never joined, so nobody is issuing orders for that robot |

`throttled` is a divergence from the design note's enum, which folded 429 into
`transport_error`; it is kept separate because a throttled episode and a broken
one need different answers.

**Every string that lands in the replay** — `say`, `notes`, the policy label,
`stopDetail`, recorded error text — is truncated on **rune** boundaries. Byte
truncation is what makes a replay that renders in a browser fail a strict UTF-8
parser.

## The results document

Closed schema; `game.results_schema` in the manifest lists exactly these keys and
`tests/test_rware_manifest.nim` asserts the two agree.

```json
{
  "names":          ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"],
  "aliases":        ["Alpha", "Bravo", "Charlie", "Delta"],
  "scores":         [1405, 1403, 1403, 1403],
  "win":            [true, true, true, true],
  "winner":         null,
  "reason":         "complete",
  "teamDelivered":  14,
  "parDeliveries":  8,
  "delivered":      [5, 3, 3, 3],
  "stowed":         [5, 3, 2, 3],
  "blockedMoves":   [22, 61, 18, 40],
  "jams":           3,
  "jamTicks":       47,
  "longestJamTicks":21,
  "finalTick":      500,
  "turnsPlayed":    25,
  "seed":           1734029581,
  "policyKinds":    ["llm", "llm", "scripted", "scripted"],
  "crossPlay":      true,
  "llmTurns":       [25, 24, 0, 0],
  "fallbackTurns":  [0, 1, 0, 0],
  "ordersRejected": [0, 2, 0, 0],
  "deadSeats":      [false, false, false, false],
  "stopDetail":     ""
}
```

`winner` is always `null`: a cooperative episode has no winner. `win[s]` is
`teamDelivered >= parDeliveries`, the same boolean for all four seats. `reason`
is a closed enum: `complete` (500 ticks ran), `deadline` (the wall-clock stop
fired — declared acceptable, settled with the real deliveries so far, and the
budget guard exists so it should never happen), `fault` (an unexpected
exception; the episode is settled from the last completed tick, `stopDetail`
names it, and the artifacts are still written).

Adding a key means updating `fleetResultsJson`, the manifest's `results_schema`
and `tools/ci/docker_smoke.sh`'s expected-key set in the same commit — Coworld
schemas are closed and undeclared keys are dropped.

## The replay

`COWLDRWH` — magic, format version, game name and version, the **resolved config
JSON**, then a record stream and one `gameHash` per frame. Little-endian,
length-prefixed. Everything is re-derived from those bytes; no server is
contacted except S3 for the file.

| Content | Carries |
|---|---|
| header | magic `COWLDRWH`, format version, `rware-warehouse`, `gameVersion` |
| config JSON | seed, `num_agents`, `shelfColumns`, `shelfRows`, `columnHeight`, `requestQueue`, `maxTicks`, `turnTicks`, `parDeliveries`, `sensorRange`, `jamTicks`, `players[].name` (real names), `slots[]`, `fastMode` |
| joins | per seat: name, slot, token |
| gameStart | the frame the shift starts on |
| orders | per turn, per seat: the accepted order — this game's entire input log |
| chats | `register` / `directive` / `fallback` / `budget_guard` / `result` records |
| stop | the load-bearing wall-clock or fault stop |
| hashes | one `gameHash` per frame — the integrity chain the viewer checks |

The **stop is a record, not an inference**: a wall-clock fact cannot be
re-derived from sim state, so it is written once and applied by the *same proc*
(`sim.applyStop`) on record and on playback. `tests/test_rware_replay.nim` runs
the record -> re-derive check for **every** end reason, not just the healthy one.

`gameHash` mixes, in this fixed order: per robot
`(slot, x, y, facing, carryingShelfId, stuck)`; per shelf `(id, x, y, carrier)`;
the request queue in order; `teamDelivered`, per-seat `delivered` and `stowed`;
the active jam set; then `tick`.

### The derived event vocabulary

Ten kinds, derived from state deltas and the frame's chat records during
playback, so they cost no replay bytes and are identical live and in replay:

`turn {n}`, `order {slot, verb, arg}`, `say {slot, text}`,
`fallback {slot, cause}`, `load {slot, shelf, cell}`,
`deliver {slot, shelf, station, total}`, `stow {slot, shelf, cell}`,
`jam {slots, cells, tick}`, `jamclear {slots, ticks}`,
`end {reason, teamDelivered, par}`.

Only `delivery`, `jam`, `fallback` and `end` become scrubber **beats**; `turn`,
`order`, `say`, `load` and `stow` drive the feed.

### Reading a replay with no toolchain

```bash
curl -sSL "$replay_url" -o /tmp/ep.replay
python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
jq -e . /tmp/ep.json >/dev/null                       # strict UTF-8 JSON: ok
jq -r '.protocol, .results.reason, .results.teamDelivered' /tmp/ep.json
jq -r '[.orders[]|select(.source=="llm")]|length, .fallbacks, (.radio|length)' \
  /tmp/ep.json
```
